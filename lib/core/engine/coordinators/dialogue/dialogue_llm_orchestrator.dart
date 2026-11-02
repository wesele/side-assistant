import 'dart:async';

import '../../support/streaming_json_reply_parser.dart';
import '../../../models/app_settings.dart';
import '../../../models/assistant_status.dart';
import '../../../models/camera_capture_result.dart';
import '../../../platform/foundation_bridge.dart';
import '../../../ports/audio_stream_control_port.dart';
import '../../../ports/llm_port.dart';
import '../../../ports/prompt_sound_port.dart';
import '../../../ports/session_message_port.dart';
import '../../../ports/trigger_matcher_port.dart';
import '../../../ports/tts_port.dart';
import '../../engine_events.dart';
import 'dialogue_state_machine.dart';
import 'streaming_sentence_segmenter.dart';

/// 大模型对话流式编排器 (DialogueLlmOrchestrator)
///
/// 专职负责多轮 LLM 流式交互、代系竞争防护 (_activeGenerationId)、
/// 流式思维链/JSON 意图解析 (StreamingJsonReplyParser)、
/// 实时断句与 TTS 队列推送，以及现场相机快门音与抓拍多模态联动。
/// 纯 Dart 实现，零 `dart:ui` 或 `package:flutter` 依赖。
class DialogueLlmOrchestrator {
  AppSettings settings;
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;

  final SessionMessagePort sessionMessagePort;
  final AudioStreamControlPort audioControlPort;
  final LlmPort llmService;
  final TtsPort ttsService;
  final PromptSoundPort promptSoundService;
  final TriggerMatcherPort triggerMatcher;
  final DialogueStateMachine stateMachine;

  /// 外部相机抓拍源回调
  final Future<CameraCaptureResult> Function()? onCapturePhotoDirect;

  // 跨组件协同回调
  final void Function(bool matched)? onWakeWordMatched;
  final void Function()? onScheduleUnmatchedSpeechFade;
  final Future<void> Function()? onPlayAcknowledgeBeep;
  final Future<void> Function({bool playVoice})? onStartNewSession;
  final void Function()? onResetDialogueInput;

  // 代次代系戳（防异步响应竞争）与当前播报文案缓冲
  int _activeGenerationId = 0;
  String _currentSpeakingReply = '';

  DialogueLlmOrchestrator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    required this.sessionMessagePort,
    required this.audioControlPort,
    required this.llmService,
    required this.ttsService,
    required this.promptSoundService,
    required this.triggerMatcher,
    required this.stateMachine,
    this.onCapturePhotoDirect,
    this.onWakeWordMatched,
    this.onScheduleUnmatchedSpeechFade,
    this.onPlayAcknowledgeBeep,
    this.onStartNewSession,
    this.onResetDialogueInput,
  });

  /// 当前活跃的代次代系编号
  int get activeGenerationId => _activeGenerationId;

  /// 当前正在流式回答/播报的正文内容
  String get currentSpeakingReply => _currentSpeakingReply;

  /// 自增生成新一代次代系戳
  int nextGenerationId() => ++_activeGenerationId;

  /// 取消并作废当前所有活跃的流式代次
  void cancelActiveGeneration() {
    _activeGenerationId++;
  }

  /// 重置当前播报文本缓冲
  void resetSpeakingReply() {
    _currentSpeakingReply = '';
  }

  /// 提请大模型流式推理、思维链解析、工具派发与分句 TTS
  Future<void> submitToLlm(
    String userText, {
    Uint8List? preCapturedImageBytes,
    String? preCapturedImagePath,
    bool enableTts = true,
    bool isExplicitCommand = false,
  }) async {
    final currentGen = nextGenerationId();
    stateMachine.setStatus(AssistantStatus.thinking, '正在思考回复...');

    final activeSessionId = sessionMessagePort.currentSessionId;
    final parser = StreamingJsonReplyParser();
    final sentenceSegmenter = StreamingSentenceSegmenter(ttsService: ttsService);
    _currentSpeakingReply = '';

    String? userMsgId;
    String? assistantMsgId;
    int? assistantMsgIndex;
    bool messagesCreatedInUi = false;
    Uint8List? newlyCapturedPhotoBytes = preCapturedImageBytes;
    String? newlyCapturedPhotoPath = preCapturedImagePath;

    void ensureMessagesCreated() {
      if (messagesCreatedInUi) return;
      final pair = sessionMessagePort.appendUserAndPlaceholderMessage(
        userText,
        imagePath: newlyCapturedPhotoPath,
      );
      userMsgId = pair.userMsgId;
      assistantMsgId = pair.assistantMsgId;
      assistantMsgIndex = pair.assistantMsgIndex;

      messagesCreatedInUi = true;
      stateMachine.setStatus(
        enableTts ? AssistantStatus.playing : AssistantStatus.thinking,
        '正在回答...',
      );
      onNotify();
    }

    if (!enableTts || isExplicitCommand) {
      ensureMessagesCreated();
    }

    parser.onIntentResolved = (intent, shouldReply) async {
      if (sessionMessagePort.currentSessionId != activeSessionId ||
          currentGen != _activeGenerationId) {
        return;
      }

      if (!shouldReply) {
        debugPrint(
          '[DialogueLlmOrchestrator] 大模型判定非对话意图 (intent=$intent)，已忽略该条语音',
        );
        stateMachine.setStatus(
          AssistantStatus.idle,
          '未检测到对话意图',
        );
        onNotify();
        onScheduleUnmatchedSpeechFade?.call();
        return;
      }

      if (intent == 'start_or_continue') {
        onWakeWordMatched?.call(true);
        stateMachine.enterContinuousMode();
        if (onPlayAcknowledgeBeep != null) {
          unawaited(onPlayAcknowledgeBeep!());
        }
      } else if (intent == 'new_session') {
        onWakeWordMatched?.call(true);
        stateMachine.enterContinuousMode();
        if (onPlayAcknowledgeBeep != null) {
          unawaited(onPlayAcknowledgeBeep!());
        }
        if (onStartNewSession != null) {
          await onStartNewSession!(playVoice: false);
        }
      } else if (intent == 'exit') {
        unawaited(stateMachine.exitContinuousMode(byUser: false));
      }

      ensureMessagesCreated();
    };

    parser.onReplyChunk = (chunk) {
      if (sessionMessagePort.currentSessionId != activeSessionId ||
          currentGen != _activeGenerationId) {
        return;
      }
      ensureMessagesCreated();

      _currentSpeakingReply += chunk;

      if (assistantMsgId != null && assistantMsgIndex != null) {
        sessionMessagePort.updateAssistantMessageContent(
          assistantMsgId!,
          assistantMsgIndex!,
          _currentSpeakingReply,
        );
      }

      if (enableTts) {
        sentenceSegmenter.feedChunk(
          chunk,
          shouldCancel: () =>
              currentGen != _activeGenerationId ||
              stateMachine.status != AssistantStatus.playing,
          canEnqueue: () =>
              stateMachine.status == AssistantStatus.playing &&
              currentGen == _activeGenerationId,
        );
      }
    };

    try {
      final llmStopwatch = Stopwatch()..start();
      var loggedFirstToken = false;

      await for (final token in llmService.sendChatStream(
        history: sessionMessagePort.messages,
        newUserContent: userText,
        sessionId: activeSessionId,
        imageBytes: newlyCapturedPhotoBytes,
        isDialogueIntentMode: true,
        isInContinuousMode: stateMachine.isInContinuousMode,
        onCapturePhoto: () async {
          unawaited(promptSoundService.playShutterSound());
          stateMachine.setStatus(AssistantStatus.thinking, '正在调用相机拍摄现场画面...');
          try {
            if (onCapturePhotoDirect == null) return null;
            final captureRes = await onCapturePhotoDirect!();
            newlyCapturedPhotoBytes = captureRes.imageBytes;
            newlyCapturedPhotoPath = captureRes.filePath;

            if (userMsgId != null) {
              sessionMessagePort.updateMessageImagePath(
                userMsgId!,
                captureRes.filePath,
              );
            }

            return captureRes.imageBytes;
          } catch (e) {
            debugPrint(
              '[DialogueLlmOrchestrator] capturePhoto 工具调用异常: $e',
            );
            return null;
          }
        },
        onToolCall: (toolName, query) {
          if (sessionMessagePort.currentSessionId != activeSessionId) return;
          final q = query.trim();
          final searchDisplay = toolName == 'capture_photo'
              ? '正在调用相机拍照...'
              : (q.isNotEmpty ? '正在搜索：$q...' : '正在查询...');
          if (assistantMsgId != null && assistantMsgIndex != null) {
            sessionMessagePort.updateAssistantMessageContent(
              assistantMsgId!,
              assistantMsgIndex!,
              searchDisplay,
            );
          }
        },
      )) {
        if (sessionMessagePort.currentSessionId != activeSessionId ||
            currentGen != _activeGenerationId) {
          debugPrint(
            '[DialogueLlmOrchestrator] 收到新请求或会话切换，终止当前过时的流式响应 (gen=$currentGen < active=$_activeGenerationId)',
          );
          break;
        }
        if (stateMachine.status != AssistantStatus.playing &&
            stateMachine.status != AssistantStatus.thinking) {
          debugPrint(
            '[DialogueLlmOrchestrator] 状态已切换(${stateMachine.status.name})，终止接收流式Token',
          );
          break;
        }
        if (!loggedFirstToken && token.isNotEmpty) {
          loggedFirstToken = true;
          debugPrint(
            '[DialogueLlmOrchestrator] 大模型首字延迟 ${llmStopwatch.elapsedMilliseconds}ms',
          );
        }
        parser.feed(token);
      }

      debugPrint(
        '[DialogueLlmOrchestrator] 大模型输出完成，总耗时 ${llmStopwatch.elapsedMilliseconds}ms',
      );

      if (currentGen != _activeGenerationId) {
        debugPrint(
          '[DialogueLlmOrchestrator] 请求已过期(gen=$currentGen != active=$_activeGenerationId)，忽略后续播报与处理',
        );
        return;
      }

      final decision = parser.finish();

      if (!decision.shouldReply) {
        if (stateMachine.status != AssistantStatus.idle) {
          stateMachine.setStatus(AssistantStatus.idle, '未检测到对话意图');
          onScheduleUnmatchedSpeechFade?.call();
        }
        return;
      }

      ensureMessagesCreated();

      if (userMsgId != null &&
          ((newlyCapturedPhotoPath != null &&
                  newlyCapturedPhotoPath!.isNotEmpty) ||
              (newlyCapturedPhotoBytes != null &&
                  newlyCapturedPhotoBytes!.isNotEmpty))) {
        final persistedPath = await sessionMessagePort.persistImage(
          sessionId: sessionMessagePort.currentSessionId,
          messageId: userMsgId!,
          sourcePath: newlyCapturedPhotoPath,
          imageBytes: newlyCapturedPhotoBytes,
        );
        if (persistedPath != null) {
          sessionMessagePort.updateMessageImagePath(userMsgId!, persistedPath);
        }
      }

      if (enableTts) {
        await sentenceSegmenter.flush(
          shouldCancel: () =>
              currentGen != _activeGenerationId ||
              stateMachine.status != AssistantStatus.playing,
          canEnqueue: () =>
              currentGen == _activeGenerationId &&
              sessionMessagePort.currentSessionId == activeSessionId &&
              stateMachine.status == AssistantStatus.playing,
          waitForCompletion: true,
        );
      }

      if (assistantMsgId != null && assistantMsgIndex != null) {
        sessionMessagePort.updateAssistantMessageContent(
          assistantMsgId!,
          assistantMsgIndex!,
          decision.reply.isNotEmpty ? decision.reply : _currentSpeakingReply,
        );
      }
    } catch (e, st) {
      if (currentGen != _activeGenerationId) return;
      emit(EngineErrorEvent('请求大模型失败: $e', errorObject: e, stackTrace: st));
      if (sessionMessagePort.currentSessionId == activeSessionId) {
        if (assistantMsgId != null && assistantMsgIndex != null) {
          sessionMessagePort.updateAssistantMessageContent(
            assistantMsgId!,
            assistantMsgIndex!,
            '请求大模型失败: $e',
          );
        }
        if (enableTts) {
          await ttsService.speakImmediate('抱歉，网络或模型请求异常');
        }
      }
    } finally {
      if (sessionMessagePort.currentSessionId == activeSessionId) {
        await sessionMessagePort.syncCurrentSession(persist: true);
      }
      if (currentGen == _activeGenerationId) {
        _currentSpeakingReply = '';
        if (stateMachine.status == AssistantStatus.playing ||
            stateMachine.status == AssistantStatus.thinking) {
          audioControlPort.flushBuffers(cooldownMs: 500);
          final exitHintWord = settings.exitContinuousWords.isNotEmpty
              ? settings.exitContinuousWords.first
              : '结束对话';
          final idleHint = stateMachine.isInContinuousMode
              ? '连续对话中，可直接说话（说“$exitHintWord”退出）'
              : (stateMachine.isWakeWordRequired
                  ? '待机中，可说“${settings.startWord}”随时呼唤'
                  : '待机中，可随时直接说话交互');
          stateMachine.setStatus(AssistantStatus.idle, idleHint);
          stateMachine.resetContinuousTimer();
        }
      }
    }
  }

  /// 准备直接用户文本输入（打断既有播报、检测停止/重置词）
  Future<bool> prepareDirectUserInput(
    String text, {
    bool playVoice = true,
  }) async {
    cancelActiveGeneration();
    await ttsService.stop();
    audioControlPort.flushBuffers(cooldownMs: 300);
    onResetDialogueInput?.call();

    final resetMatch = await triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      if (onStartNewSession != null) {
        await onStartNewSession!(playVoice: playVoice);
      }
      return true;
    }

    if (text == '停止' || text == '暂停') {
      stateMachine.setStatus(AssistantStatus.idle, '已停止朗读，返回待机');
      return true;
    }

    return false;
  }

  /// 发送直接用户语音转写输入
  Future<void> sendDirectUserMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (await prepareDirectUserInput(text)) return;

    if (onPlayAcknowledgeBeep != null) {
      unawaited(onPlayAcknowledgeBeep!());
    }
    await submitToLlm(text, isExplicitCommand: true);
  }

  /// 发送纯文本消息（不触发 TTS 朗读播报）
  Future<void> sendTextMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (await prepareDirectUserInput(text, playVoice: false)) return;

    await submitToLlm(text, enableTts: false);
  }

  /// 增量更新配置
  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
  }
}
