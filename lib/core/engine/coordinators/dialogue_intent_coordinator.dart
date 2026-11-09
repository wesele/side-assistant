import 'dart:async';

import '../../constants/app_constants.dart';
import '../engine_events.dart';
import '../../models/app_settings.dart';
import '../../models/assistant_status.dart';
import '../../models/camera_capture_result.dart';
import '../../platform/foundation_bridge.dart';
import '../../ports/audio_stream_control_port.dart';
import '../../ports/gemini_live_session_port.dart';
import '../../ports/knowledge_port.dart';
import '../../ports/llm_port.dart';
import '../../ports/prompt_sound_port.dart';
import '../../ports/session_message_port.dart';
import '../../ports/speaker_verification_port.dart';
import '../../ports/trigger_matcher_port.dart';
import '../../ports/tts_port.dart';
import '../support/trigger_matcher.dart' show TriggerMatcher;
import 'dialogue/dialogue_barge_in_controller.dart';
import 'dialogue/dialogue_llm_orchestrator.dart';
import 'dialogue/dialogue_state_machine.dart';
import 'dialogue/gemini_live_turn_coordinator.dart';
import 'dialogue/streaming_sentence_segmenter.dart';
import 'dialogue/transcript_trigger_coordinator.dart';

/// 对话决策编排门面协调器 (DialogueIntentCoordinator Facade)
///
/// 统一持有并编排 5 个高内聚子组件：
/// - [DialogueStateMachine]: 负责有限状态跃迁、连续模式与 5 大超时计时器；
/// - [DialogueBargeInController]: 负责播报打断、防外放回声剥离与声学 400ms 冷却；
/// - [StreamingSentenceSegmenter]: 负责流式标点断句与文本累加缓冲；
/// - [TranscriptTriggerCoordinator]: 负责开始/结束词匹配、两阶段 ASR 仲裁与串行调度；
/// - [DialogueLlmOrchestrator]: 负责多轮 LLM 调用、代系防竞争、思维链解析与相机视觉协同。
///
/// 对外完全保持 100% 向后兼容的公共 API 契约与方法签名。纯 Dart 实现，零 `dart:ui` 依赖。
class DialogueIntentCoordinator {
  AppSettings settings;
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;

  /// 音频采集流控制端口 (ISP)
  final AudioStreamControlPort audioControlPort;

  /// 主人声纹识别与鉴权端口 (ISP)
  final SpeakerVerificationPort speakerVerificationPort;

  /// 会话状态与消息增量管理端口 (ISP)
  final SessionMessagePort sessionMessagePort;

  /// 向后兼容既有代码与测试的别名访问器
  AudioStreamControlPort get voiceCoordinator => audioControlPort;
  SessionMessagePort get sessionCoordinator => sessionMessagePort;

  final Future<CameraCaptureResult> Function()? onCapturePhotoDirect;
  void Function({
    String? forText,
    required String llmDecision,
    bool? shouldReply,
    String? intent,
    String? detail,
  })? onSpeechDecision;

  // 内部持有的专属子组件
  late final DialogueStateMachine stateMachine;
  late final DialogueBargeInController bargeInController;
  late final StreamingSentenceSegmenter sentenceSegmenter;
  late final TranscriptTriggerCoordinator transcriptCoordinator;
  late final DialogueLlmOrchestrator llmOrchestrator;
  late final GeminiLiveTurnCoordinator geminiLiveCoordinator;

  // 领域端口与服务
  late TriggerMatcherPort triggerMatcher;
  late LlmPort llmService;
  KnowledgePort? lightRagService;
  late TtsPort ttsService;
  late PromptSoundPort promptSoundService;

  int acknowledgeBeepCount = 0;

  DialogueIntentCoordinator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    AudioStreamControlPort? audioControlPort,
    SpeakerVerificationPort? speakerVerificationPort,
    SessionMessagePort? sessionMessagePort,
    // 向后兼容旧版调用与测试形参
    dynamic voiceCoordinator,
    dynamic sessionCoordinator,
    this.onCapturePhotoDirect,
    TriggerMatcherPort? triggerMatcher,
    LlmPort? llmService,
    KnowledgePort? lightRagService,
    TtsPort? ttsService,
    PromptSoundPort? promptSoundService,
    // 可选的子组件注入（支持单元测试精准 Mock）
    DialogueStateMachine? stateMachine,
    DialogueBargeInController? bargeInController,
    StreamingSentenceSegmenter? sentenceSegmenter,
    TranscriptTriggerCoordinator? transcriptCoordinator,
    DialogueLlmOrchestrator? llmOrchestrator,
    GeminiLiveSessionPort? geminiLiveSession,
    GeminiLiveTurnCoordinator? geminiLiveCoordinator,
    Duration? toolProgressInterval,
  })  : audioControlPort = audioControlPort ??
            (voiceCoordinator is AudioStreamControlPort
                ? voiceCoordinator
                : throw ArgumentError(
                    'Must provide either audioControlPort or voiceCoordinator',
                  )),
        speakerVerificationPort = speakerVerificationPort ??
            (voiceCoordinator is SpeakerVerificationPort
                ? voiceCoordinator
                : throw ArgumentError(
                    'Must provide either speakerVerificationPort or voiceCoordinator',
                  )),
        sessionMessagePort = sessionMessagePort ??
            (sessionCoordinator is SessionMessagePort
                ? sessionCoordinator
                : throw ArgumentError(
                    'Must provide either sessionMessagePort or sessionCoordinator',
                  )) {
    this.triggerMatcher =
        triggerMatcher ?? (TriggerMatcher(settings: settings)..warmUp());
    this.llmService = llmService ??
        (LlmFactoryRegistry.defaultFactory?.call(settings) ??
            const NoopLlmPort());
    this.lightRagService = lightRagService ??
        ((settings.enableLightRag && settings.lightRagBaseUrl.trim().isNotEmpty)
            ? KnowledgeFactoryRegistry.defaultFactory?.call(
                baseUrl: settings.lightRagBaseUrl,
                describeImage: (bytes) => this.llmService.describeImage(bytes),
              )
            : null);
    if (this.lightRagService != null) {
      unawaited(this.lightRagService!.retryPending());
    }
    this.ttsService = ttsService ??
        (TtsFactoryRegistry.defaultFactory?.call(settings) ??
            const NoopTtsPort());
    this.promptSoundService = promptSoundService ??
        (PromptSoundFactoryRegistry.defaultFactory?.call(
              outputDeviceId: settings.audioOutputDeviceId,
            ) ??
            const NoopPromptSoundPort());

    this.sentenceSegmenter = sentenceSegmenter ??
        StreamingSentenceSegmenter(ttsService: this.ttsService);

    // 1. 初始化状态机
    this.stateMachine = stateMachine ??
        DialogueStateMachine(
          settings: settings,
          audioControlPort: this.audioControlPort,
          ttsService: this.ttsService,
          hasSessionMessages: () => this.sessionMessagePort.messages.isNotEmpty,
          onStatusChanged: (oldStatus, newStatus, hint) {
            emit(StatusChangedEvent(oldStatus, newStatus, hint: hint));
            onNotify();
          },
          onContinuousModeChanged: (enabled, reason) {
            emit(ContinuousModeChangedEvent(enabled, reason: reason));
            onNotify();
          },
          onNotify: onNotify,
          onTranscriptsCleared: () {
            this.transcriptCoordinator.clearTranscripts();
          },
          onSilenceTimeout: () => _handleSilenceTimeout(),
          onLightRagIdleReset: () => startNewSession(playVoice: false),
        );

    // 2. 初始化播报打断控制器
    this.bargeInController = bargeInController ??
        DialogueBargeInController(
          settings: settings,
          audioControlPort: this.audioControlPort,
          speakerVerificationPort: this.speakerVerificationPort,
          ttsService: this.ttsService,
          triggerMatcher: this.triggerMatcher,
          onBargeInRejected: (reason) {
            this.stateMachine.setStatus(AssistantStatus.idle, reason);
            this.transcriptCoordinator.scheduleUnmatchedSpeechFade();
          },
          onStopPlaying: (hint) async {
            this.llmOrchestrator.resetSpeakingReply();
            this.stateMachine.setStatus(AssistantStatus.idle, hint);
            onNotify();
          },
          onExitContinuous: () async {
            this.llmOrchestrator.resetSpeakingReply();
            await exitContinuousMode(byUser: true);
          },
          onBargeInAccepted: (remaining, isStartMatched) async {
            this.llmOrchestrator.resetSpeakingReply();
            if (isStartMatched) {
              this.transcriptCoordinator.isWakeWordMatched = true;
            }
            this.transcriptCoordinator.liveTranscript = remaining;
            unawaited(playAcknowledgeBeep());
            this.stateMachine.setStatus(
                  AssistantStatus.listeningContent,
                  '正在倾听打断内容...',
                );
            onNotify();
            this.stateMachine.startSilenceTimer();

            final endMatch = await this.triggerMatcher.checkEndWord(
                  this.transcriptCoordinator.liveTranscript,
                );
            if (endMatch.isMatched &&
                this.stateMachine.status == AssistantStatus.listeningContent &&
                !this.stateMachine.isDisposed) {
              await this.transcriptCoordinator.submitLiveTranscript(endMatch);
            }
          },
        );

    // 3. 初始化大模型编排器
    this.llmOrchestrator = llmOrchestrator ??
        DialogueLlmOrchestrator(
          settings: settings,
          emit: emit,
          onNotify: onNotify,
          sessionMessagePort: this.sessionMessagePort,
          audioControlPort: this.audioControlPort,
          llmService: this.llmService,
          ttsService: this.ttsService,
          promptSoundService: this.promptSoundService,
          triggerMatcher: this.triggerMatcher,
          stateMachine: this.stateMachine,
          onCapturePhotoDirect: onCapturePhotoDirect,
          onWakeWordMatched: (matched) {
            this.transcriptCoordinator.isWakeWordMatched = matched;
          },
          onScheduleUnmatchedSpeechFade: () {
            this.transcriptCoordinator.scheduleUnmatchedSpeechFade();
          },
          onPlayAcknowledgeBeep: () => playAcknowledgeBeep(),
          onStartNewSession: ({bool playVoice = false}) =>
              startNewSession(playVoice: playVoice),
          onResetDialogueInput: () {
            this.stateMachine.cancelSilenceTimer();
            this.transcriptCoordinator.clearTranscripts();
          },
          onSpeechDecision: ({
            String? forText,
            required String llmDecision,
            bool? shouldReply,
            String? intent,
            String? detail,
          }) =>
              onSpeechDecision?.call(
            forText: forText,
            llmDecision: llmDecision,
            shouldReply: shouldReply,
            intent: intent,
            detail: detail,
          ),
        );

    // 4. 初始化转写触发协调器
    this.transcriptCoordinator = transcriptCoordinator ??
        TranscriptTriggerCoordinator(
          settings: settings,
          emit: emit,
          onNotify: onNotify,
          audioControlPort: this.audioControlPort,
          speakerVerificationPort: this.speakerVerificationPort,
          triggerMatcher: this.triggerMatcher,
          ttsService: this.ttsService,
          stateMachine: this.stateMachine,
          bargeInController: this.bargeInController,
          onSubmitLlm: (prompt, {required isExplicitCommand}) =>
              this.llmOrchestrator.submitToLlm(
                    prompt,
                    isExplicitCommand: isExplicitCommand,
                  ),
          onPlayAcknowledgeBeep: () => playAcknowledgeBeep(),
          onStartNewSession: ({bool playVoice = true}) =>
              startNewSession(playVoice: playVoice),
          onExitContinuous: () => exitContinuousMode(byUser: true),
          onSpeechDecision: ({
            String? forText,
            required String llmDecision,
            bool? shouldReply,
            String? intent,
            String? detail,
          }) =>
              onSpeechDecision?.call(
            forText: forText,
            llmDecision: llmDecision,
            shouldReply: shouldReply,
            intent: intent,
            detail: detail,
          ),
        );

    // 5. 初始化 Gemini 3.8 Live 全双工轮次协调器
    this.geminiLiveCoordinator = geminiLiveCoordinator ??
        GeminiLiveTurnCoordinator(
          settings: settings,
          emit: emit,
          onNotify: onNotify,
          sessionMessagePort: this.sessionMessagePort,
          promptSoundService: this.promptSoundService,
          stateMachine: this.stateMachine,
          transcriptCoordinator: this.transcriptCoordinator,
          onCapturePhotoDirect: onCapturePhotoDirect,
          liveSession: geminiLiveSession,
          onSpeakStatus: (text) => this.ttsService.speakImmediate(text),
          onStopSpeakStatus: () => this.ttsService.stop(),
          toolProgressInterval: toolProgressInterval,
          onSpeechDecision: ({
            String? forText,
            required String llmDecision,
            bool? shouldReply,
            String? intent,
            String? detail,
          }) =>
              onSpeechDecision?.call(
            forText: forText,
            llmDecision: llmDecision,
            shouldReply: shouldReply,
            intent: intent,
            detail: detail,
          ),
        );
  }

  // ---- 100% 向后兼容的公共状态 Getter/Setter 委托 ----

  bool get isDisposed => stateMachine.isDisposed;
  AssistantStatus get status => stateMachine.status;
  String get statusHint => stateMachine.statusHint;
  String get displayTranscript => transcriptCoordinator.displayTranscript;
  String get liveTranscript => transcriptCoordinator.liveTranscript;
  set liveTranscript(String val) => transcriptCoordinator.liveTranscript = val;
  String get lastRecognizedSpeech => transcriptCoordinator.lastRecognizedSpeech;
  set lastRecognizedSpeech(String val) =>
      transcriptCoordinator.lastRecognizedSpeech = val;
  String get rawSpeechInSession => transcriptCoordinator.rawSpeechInSession;
  set rawSpeechInSession(String val) =>
      transcriptCoordinator.rawSpeechInSession = val;
  bool get isWakeWordMatched => transcriptCoordinator.isWakeWordMatched;
  set isWakeWordMatched(bool val) =>
      transcriptCoordinator.isWakeWordMatched = val;
  bool get isInContinuousMode => stateMachine.isInContinuousMode;
  set isInContinuousMode(bool val) {
    if (val) {
      stateMachine.enterContinuousMode();
    } else {
      unawaited(stateMachine.exitContinuousMode(byUser: false));
    }
  }

  String get currentSpeakingReply => settings.isGeminiLiveMode
      ? geminiLiveCoordinator.currentSpeakingReply
      : llmOrchestrator.currentSpeakingReply;
  set currentSpeakingReply(String val) {
    if (val.isEmpty) {
      llmOrchestrator.resetSpeakingReply();
    }
  }

  String get statusShortLabel => stateMachine.statusShortLabel;
  bool get isWakeWordRequired =>
      settings.isGeminiLiveMode ? false : stateMachine.isWakeWordRequired;

  // ---- 100% 向后兼容的核心业务方法委托 ----

  void setStatus(AssistantStatus newStatus, [String? hint]) =>
      stateMachine.setStatus(newStatus, hint);

  @visibleForTesting
  void setStatusForTesting(AssistantStatus status, String hint) =>
      stateMachine.setStatusForTesting(status, hint);

  void enterContinuousMode() => stateMachine.enterContinuousMode();

  @visibleForTesting
  void enterContinuousModeForTesting() =>
      stateMachine.enterContinuousModeForTesting();

  Future<void> exitContinuousMode({bool byUser = false, String? reason}) =>
      stateMachine.exitContinuousMode(byUser: byUser, reason: reason);

  void resetContinuousTimer() => stateMachine.resetContinuousTimer();

  void startSilenceTimer({double? overrideSeconds}) =>
      stateMachine.startSilenceTimer(overrideSeconds: overrideSeconds);

  void resetSilenceTimer() => stateMachine.resetSilenceTimer();

  Future<void> processRecognizedText(String recognizedText) =>
      transcriptCoordinator.processRecognizedText(recognizedText);

  Future<void> processPartialTranscript(String partialText) =>
      transcriptCoordinator.processPartialTranscript(partialText);

  Future<void> processFinalTranscript(String finalText) =>
      transcriptCoordinator.processFinalTranscript(finalText);

  Future<void> handlePlayingText(String rawText) =>
      bargeInController.handlePlayingText(
        rawText,
        isInContinuousMode: stateMachine.isInContinuousMode,
      );

  Future<void> handlePlayingBargeIn(String text) =>
      bargeInController.handlePlayingBargeIn(
        text,
        isInContinuousMode: stateMachine.isInContinuousMode,
      );

  Future<void> submitToLlm(
    String userText, {
    Uint8List? preCapturedImageBytes,
    String? preCapturedImagePath,
    bool enableTts = true,
    bool isExplicitCommand = false,
  }) {
    if (settings.isGeminiLiveMode) {
      return geminiLiveCoordinator.sendClientText(
        userText,
        preCapturedImageBytes: preCapturedImageBytes,
        preCapturedImagePath: preCapturedImagePath,
      );
    }
    return llmOrchestrator.submitToLlm(
      userText,
      preCapturedImageBytes: preCapturedImageBytes,
      preCapturedImagePath: preCapturedImagePath,
      enableTts: enableTts,
      isExplicitCommand: isExplicitCommand,
    );
  }

  Future<void> sendDirectUserMessage(String rawText) async {
    if (settings.isGeminiLiveMode) {
      final text = rawText.trim();
      if (text.isEmpty) return;
      await geminiLiveCoordinator.stopSpeaking();
      if (await prepareDirectUserInput(text)) return;
      await geminiLiveCoordinator.sendClientText(text);
      return;
    }
    await llmOrchestrator.sendDirectUserMessage(rawText);
  }

  Future<void> sendTextMessage(String rawText) async {
    if (settings.isGeminiLiveMode) {
      final text = rawText.trim();
      if (text.isEmpty) return;
      await geminiLiveCoordinator.stopSpeaking();
      if (await prepareDirectUserInput(text, playVoice: false)) return;
      await geminiLiveCoordinator.sendClientText(text);
      return;
    }
    await llmOrchestrator.sendTextMessage(rawText);
  }

  Future<bool> prepareDirectUserInput(
    String text, {
    bool playVoice = true,
  }) =>
      llmOrchestrator.prepareDirectUserInput(text, playVoice: playVoice);

  Future<void> simulateUserInput(String text) => processRecognizedText(text);

  Future<void> triggerWake({String? wakeWord}) =>
      transcriptCoordinator.triggerWake(wakeWord: wakeWord);

  /// 重置状态机回待机态
  Future<void> resetToIdle() async {
    llmOrchestrator.cancelActiveGeneration();
    stateMachine.cancelSilenceTimer();
    transcriptCoordinator.cancelUnmatchedSpeechTimer();
    unawaited(ttsService.stop());
    unawaited(geminiLiveCoordinator.stopSpeaking());
    transcriptCoordinator.clearTranscripts();
    stateMachine.setStatus(AssistantStatus.idle, '已重置回待机');
  }

  /// 开启新会话，重置上下文
  Future<void> startNewSession({bool playVoice = true}) async {
    await sessionMessagePort.startNewSession();
    stateMachine.cancelSilenceTimer();
    audioControlPort.flushBuffers(cooldownMs: 400);
    transcriptCoordinator.clearTranscripts();
    transcriptCoordinator.cancelUnmatchedSpeechTimer();
    stateMachine.setStatus(AssistantStatus.idle, '已开启全新会话，上下文已重置');
    await ttsService.stop();
    await geminiLiveCoordinator.onSessionChanged(resetSession: true);

    if (playVoice && !settings.isGeminiLiveMode) {
      await ttsService.speakImmediate(AppConstants.resetPromptReply);
      audioControlPort.flushBuffers(cooldownMs: 400);
    }
  }

  /// 切换当前会话并协调声学与状态机复位
  Future<void> switchSession(String sessionId) async {
    if (sessionId == sessionMessagePort.currentSessionId) return;

    stateMachine.cancelSilenceTimer();
    audioControlPort.flushBuffers(cooldownMs: 400);
    llmOrchestrator.resetSpeakingReply();

    final target = await sessionMessagePort.switchSession(sessionId);
    if (target == null) return;

    transcriptCoordinator.clearTranscripts();
    transcriptCoordinator.cancelUnmatchedSpeechTimer();
    stateMachine.setStatus(AssistantStatus.idle, '已切换到对话「${target.title}」');
    await ttsService.stop();
    await geminiLiveCoordinator.onSessionChanged(resetSession: false);
  }

  /// 播放激活/结束提示轻滴声
  Future<void> playAcknowledgeBeep() async {
    acknowledgeBeepCount++;
    emit(SoundEffectTriggeredEvent('acknowledge_beep'));
    if (!settings.enablePromptTone) return;
    try {
      await promptSoundService
          .playAcknowledgeBeep()
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  Future<void> stopSpeaking() async {
    if (settings.isGeminiLiveMode) {
      await geminiLiveCoordinator.stopSpeaking();
    }
    await ttsService.stop();
  }

  Future<void> speakImmediate(String text) => ttsService.speakImmediate(text);

  Future<void> previewVoice({String? voice, String? text}) {
    final v = voice?.trim();
    if ((v != null && AppConstants.geminiLiveVoices.contains(v)) ||
        (v == null && settings.isGeminiLiveMode)) {
      final targetVoice =
          (v != null && v.isNotEmpty) ? v : settings.geminiLiveVoice;
      return geminiLiveCoordinator.previewVoice(
        voice: targetVoice,
        text: text,
      );
    }
    return ttsService.previewVoice(
      voice: voice ?? settings.edgeVoice,
      text: text ?? '你好，我是随身语音管家，很高兴为你服务。',
    );
  }

  /// 局部增量应用配置更新
  void updateSettings(AppSettings newSettings) {
    final oldSettings = settings;
    settings = newSettings;

    stateMachine.updateSettings(newSettings);
    bargeInController.updateSettings(newSettings);
    llmOrchestrator.updateSettings(newSettings);
    transcriptCoordinator.updateSettings(newSettings);
    geminiLiveCoordinator.updateSettings(newSettings);

    final llmChanged = oldSettings.llm != newSettings.llm;
    final ttsChanged = oldSettings.tts != newSettings.tts;

    if (llmChanged) {
      llmService.applyConfig(newSettings.llm);
      if (oldSettings.enableLightRag != newSettings.enableLightRag ||
          oldSettings.lightRagBaseUrl != newSettings.lightRagBaseUrl) {
        lightRagService = (settings.enableLightRag &&
                settings.lightRagBaseUrl.trim().isNotEmpty)
            ? KnowledgeFactoryRegistry.defaultFactory?.call(
                baseUrl: settings.lightRagBaseUrl,
                describeImage: (bytes) => llmService.describeImage(bytes),
              )
            : null;
        sessionMessagePort.updateLightRagService(lightRagService);
        if (lightRagService != null) {
          unawaited(lightRagService!.retryPending());
        }
      }
    }

    if (ttsChanged) {
      ttsService.applyConfig(newSettings.tts);
    }

    triggerMatcher = TriggerMatcher(settings: settings);
    triggerMatcher.warmUp();
  }

  /// 销毁协调器与释放内部资源
  void dispose() {
    llmOrchestrator.cancelActiveGeneration();
    stateMachine.dispose();
    bargeInController.dispose();
    transcriptCoordinator.dispose();
    geminiLiveCoordinator.dispose();
    ttsService.dispose();
    promptSoundService.dispose();
  }

  Future<void> _handleSilenceTimeout() async {
    if (stateMachine.status != AssistantStatus.listeningContent) return;

    final pending = transcriptCoordinator.rawSpeechInSession.isNotEmpty
        ? transcriptCoordinator.rawSpeechInSession
        : transcriptCoordinator.liveTranscript.trim();

    transcriptCoordinator.rawSpeechInSession = '';
    transcriptCoordinator.liveTranscript = '';
    audioControlPort.flushBuffers(cooldownMs: 300);

    if (pending.isNotEmpty) {
      debugPrint(
        '[DialogueIntentCoordinator] 静音超时，自动提交大模型意图判定与回答: "$pending"',
      );
      unawaited(submitToLlm(pending));
      return;
    }

    final exitHintWord = settings.exitContinuousWords.isNotEmpty
        ? settings.exitContinuousWords.first
        : '结束对话';
    final idleHint = stateMachine.isInContinuousMode
        ? '连续对话中，可直接说话（说“$exitHintWord”退出）'
        : (stateMachine.isWakeWordRequired
            ? '待机中，可说“${settings.startWord}”随时呼唤'
            : '待机中，可随时直接说话交互');
    stateMachine.setStatus(AssistantStatus.idle, idleHint);
  }
}
