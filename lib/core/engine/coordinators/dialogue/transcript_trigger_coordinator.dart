import 'dart:async';

import '../../support/transcript_processor.dart';
import '../../../models/app_settings.dart';
import '../../../models/assistant_status.dart';
import '../../../platform/foundation_bridge.dart';
import '../../../ports/audio_stream_control_port.dart';
import '../../../ports/speaker_verification_port.dart';
import '../../../ports/trigger_matcher_port.dart';
import '../../../ports/tts_port.dart';
import '../../engine_events.dart';
import 'dialogue_barge_in_controller.dart';
import 'dialogue_state_machine.dart';

/// 语音转写仲裁与触发词协调器 (TranscriptTriggerCoordinator)
///
/// 职责：
/// 1. 维护 liveTranscript、lastRecognizedSpeech、rawSpeechInSession 等转写状态；
/// 2. 串行 FIFO 队列调度避免 ASR 增量与终判并发写竞争；
/// 3. 两阶段 ASR 仲裁 (Zipformer 流式增量合并 vs SenseVoice 离线复选)；
/// 4. 唤醒词、结束词、退下词、停止打断词匹配及提示词提取；
/// 5. 未匹配语音 4 秒淡出定时器与倾听态流程调度。
///
/// 纯 Dart 实现，零 dart:ui / package:flutter 依赖。
class TranscriptTriggerCoordinator {
  AppSettings settings;
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;

  final AudioStreamControlPort audioControlPort;
  final SpeakerVerificationPort speakerVerificationPort;
  final TriggerMatcherPort triggerMatcher;
  final TtsPort ttsService;
  final DialogueStateMachine stateMachine;
  final DialogueBargeInController bargeInController;

  // 协调回调
  final Future<void> Function(String prompt, {required bool isExplicitCommand})
      onSubmitLlm;
  final Future<void> Function()? onPlayAcknowledgeBeep;
  final Future<void> Function({bool playVoice})? onStartNewSession;
  final Future<void> Function()? onExitContinuous;
  final void Function({
    String? forText,
    required String llmDecision,
    bool? shouldReply,
    String? intent,
    String? detail,
  })? onSpeechDecision;

  String liveTranscript = '';
  String lastRecognizedSpeech = '';
  String rawSpeechInSession = '';
  bool isWakeWordMatched = false;

  Future<void> _textProcessQueue = Future<void>.value();
  Timer? _unmatchedSpeechTimer;
  bool _disposed = false;

  /// 纯停止打断词集合（全句匹配）
  static const Set<String> pureStopWords = {
    '停止',
    '暂停',
    '闭嘴',
    '别说了',
    '退下',
  };

  /// 包含打断意图的关键词集合（子串匹配）
  static const List<String> stopKeywords = [
    '停止',
    '暂停',
    '别说了',
    '闭嘴',
    '别读了',
    '退下',
    '打断',
    '等等',
    '等一下',
  ];

  TranscriptTriggerCoordinator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    required this.audioControlPort,
    required this.speakerVerificationPort,
    required this.triggerMatcher,
    required this.ttsService,
    required this.stateMachine,
    required this.bargeInController,
    required this.onSubmitLlm,
    this.onPlayAcknowledgeBeep,
    this.onStartNewSession,
    this.onExitContinuous,
    this.onSpeechDecision,
  });

  bool get isDisposed => _disposed;

  String get displayTranscript =>
      stateMachine.status == AssistantStatus.listeningContent &&
              liveTranscript.isNotEmpty
          ? liveTranscript
          : lastRecognizedSpeech;

  void _emitTranscriptUpdated({bool isFinal = false}) {
    emit(TranscriptUpdatedEvent(
      live: liveTranscript,
      display: displayTranscript,
      lastRecognized: lastRecognizedSpeech,
      isWakeWordMatched: isWakeWordMatched,
      isFinal: isFinal,
    ));
  }

  /// 串行化任务队列调度
  Future<void> enqueueTextProcess(Future<void> Function() action) {
    final next = _textProcessQueue.then((_) => action());
    _textProcessQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  /// 处理接收到的实时识别文本
  Future<void> processRecognizedText(String recognizedText) {
    if (speakerVerificationPort.isEnrolling) {
      debugPrint(
        '[TranscriptTriggerCoordinator] 录制声纹样本中，已丢弃识别文本: "$recognizedText"',
      );
      return Future<void>.value();
    }
    final text = recognizedText.trim();
    if (text.isEmpty) return Future<void>.value();

    // 优先快速通道：如果正在播报或朗读，立即执行打断判定与处理，避免排队阻塞
    if (stateMachine.status == AssistantStatus.playing ||
        ttsService.isSpeaking) {
      return bargeInController.handlePlayingText(
        text,
        isInContinuousMode: stateMachine.isInContinuousMode,
      );
    }

    return enqueueTextProcess(() => _processRecognizedTextNow(text));
  }

  Future<void> _processRecognizedTextNow(String text) async {
    if (stateMachine.status == AssistantStatus.playing ||
        ttsService.isSpeaking) {
      await bargeInController.handlePlayingText(
        text,
        isInContinuousMode: stateMachine.isInContinuousMode,
      );
      return;
    }

    if (bargeInController.looksLikeAssistantEcho(text)) {
      final residual = bargeInController.stripAssistantEcho(text);
      final startMatch = residual.isNotEmpty
          ? await triggerMatcher.checkStartWord(residual)
          : TriggerMatchResult.none();
      if (!startMatch.isMatched) {
        debugPrint(
          '[TranscriptTriggerCoordinator] 已丢弃疑似外放回声（忽略助手自身的朗读内容）: "$text"',
        );
        onSpeechDecision?.call(
          forText: text,
          llmDecision: '外放回声已丢弃',
          shouldReply: false,
          detail: '疑似助手自身外放回声，已忽略',
        );
        return;
      }
      debugPrint(
        '[TranscriptTriggerCoordinator] 从外放尾音混音中剥离出唤醒词: 原文="$text" -> 唤醒词="${startMatch.matchedText}"',
      );
      text = startMatch.matchedText;
    }

    _unmatchedSpeechTimer?.cancel();
    lastRecognizedSpeech = text;

    _emitTranscriptUpdated();

    switch (stateMachine.status) {
      case AssistantStatus.idle:
        await _handleIdleState(text);
        break;

      case AssistantStatus.listeningContent:
        isWakeWordMatched = true;
        await _handleListeningState(text);
        break;

      case AssistantStatus.playing:
        await bargeInController.handlePlayingBargeIn(
          text,
          isInContinuousMode: stateMachine.isInContinuousMode,
        );
        break;

      case AssistantStatus.thinking:
        break;
    }
  }

  /// 处理流式增量文本
  Future<void> processPartialTranscript(String partialText) {
    if (speakerVerificationPort.isEnrolling) return Future<void>.value();
    final text = partialText.trim();
    if (text.isEmpty) return Future<void>.value();

    // 优先快速通道：播报状态下直接执行打断检测
    if (stateMachine.status == AssistantStatus.playing ||
        ttsService.isSpeaking) {
      return bargeInController.handlePlayingText(
        text,
        isInContinuousMode: stateMachine.isInContinuousMode,
      );
    }

    return enqueueTextProcess(() async {
      if (stateMachine.status == AssistantStatus.playing ||
          stateMachine.status == AssistantStatus.thinking) {
        await bargeInController.handlePlayingText(
          text,
          isInContinuousMode: stateMachine.isInContinuousMode,
        );
        return;
      }
      if (stateMachine.status != AssistantStatus.listeningContent) return;

      final combined =
          TranscriptProcessor.mergeStreamingTranscript(liveTranscript, text);
      final endMatch = await triggerMatcher.checkEndWord(combined);
      if (endMatch.isMatched &&
          stateMachine.status == AssistantStatus.listeningContent) {
        liveTranscript = combined;
        await submitLiveTranscript(endMatch);
        return;
      }
      if (combined.trim() == liveTranscript.trim()) return;
      liveTranscript = combined;
      _emitTranscriptUpdated();
      onNotify();
      stateMachine.resetSilenceTimer();
      stateMachine.resetContinuousTimer();
    });
  }

  /// 处理两阶段离线 ASR 最终精判结果
  Future<void> processFinalTranscript(String finalText) {
    if (speakerVerificationPort.isEnrolling) return Future<void>.value();
    final text = finalText.trim();
    if (text.isEmpty) return Future<void>.value();
    return enqueueTextProcess(() => _processFinalTranscriptNow(text));
  }

  Future<void> _processFinalTranscriptNow(String text) async {
    if (_disposed) return;
    if (stateMachine.status != AssistantStatus.listeningContent) {
      debugPrint(
        '[TranscriptTriggerCoordinator] 两遍解码结果到达时状态=${stateMachine.status.name}，忽略: "$text"',
      );
      return;
    }

    final merged =
        TranscriptProcessor.chooseFinalTranscript(liveTranscript, text);
    if (merged.trim() == liveTranscript.trim()) return;

    debugPrint(
      '[TranscriptTriggerCoordinator] 两遍解码替换/合并: "$liveTranscript" + "$text" -> "$merged"',
    );
    liveTranscript = merged;
    _emitTranscriptUpdated(isFinal: true);
    onNotify();
    stateMachine.resetSilenceTimer();
    stateMachine.resetContinuousTimer();

    final endMatch = await triggerMatcher.checkEndWord(liveTranscript);
    if (endMatch.isMatched &&
        stateMachine.status == AssistantStatus.listeningContent &&
        !_disposed) {
      await submitLiveTranscript(endMatch);
    }
  }

  Future<void> _handleIdleState(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (!speakerVerificationPort.verifyOwnerSpeaker(
      contextHint: '待机语音',
      onRejected: (reason) {
        onSpeechDecision?.call(
          forText: text,
          llmDecision: '声纹拦截',
          shouldReply: false,
          detail: reason,
        );
        stateMachine.setStatus(AssistantStatus.idle, reason);
        scheduleUnmatchedSpeechFade();
      },
    )) {
      return;
    }

    if (stateMachine.isInContinuousMode &&
        await triggerMatcher.checkExitContinuousWord(trimmed)) {
      onSpeechDecision?.call(
        forText: trimmed,
        llmDecision: '退出连续对话',
        shouldReply: false,
        detail: '命中退出连续对话指令',
      );
      if (onExitContinuous != null) {
        await onExitContinuous!();
      }
      return;
    }

    final resetMatch = await triggerMatcher.checkResetWord(trimmed);
    if (resetMatch.isMatched) {
      isWakeWordMatched = true;
      onSpeechDecision?.call(
        forText: trimmed,
        llmDecision: '重置会话',
        shouldReply: null,
        detail: '听到重置会话词【${resetMatch.matchedText}】',
      );
      onNotify();
      if (onStartNewSession != null) {
        await onStartNewSession!(playVoice: true);
      }
      return;
    }

    final oneShot = await triggerMatcher.extractOneShotCommand(trimmed);
    if (oneShot != null) {
      isWakeWordMatched = true;
      stateMachine.cancelSilenceTimer();
      stateMachine.resetContinuousTimer();
      rawSpeechInSession = '';
      liveTranscript = '';
      audioControlPort.resetStream();
      if (onPlayAcknowledgeBeep != null) {
        unawaited(onPlayAcknowledgeBeep!());
      }
      stateMachine.setStatus(
        AssistantStatus.thinking,
        '识别到指令【${oneShot.promptContent}】，正在请求回复...',
      );
      onSpeechDecision?.call(
        forText: trimmed,
        llmDecision: '大模型判定中...',
        shouldReply: null,
        detail: '识别到单次指令【${oneShot.promptContent}】',
      );
      await onSubmitLlm(oneShot.promptContent, isExplicitCommand: true);
      return;
    }

    final startMatch = await triggerMatcher.checkStartWord(trimmed);
    if (startMatch.isMatched) {
      isWakeWordMatched = true;
      audioControlPort.resetStream();
      if (onPlayAcknowledgeBeep != null) {
        unawaited(onPlayAcknowledgeBeep!());
      }
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '听到开始词【${startMatch.matchedText}】，正在倾听内容...（说“${settings.endWords.join("、")}”结束）',
      );
      onSpeechDecision?.call(
        forText: trimmed,
        llmDecision: '已唤醒，倾听中',
        shouldReply: null,
        detail: '听到开始词【${startMatch.matchedText}】',
      );

      final remaining =
          TranscriptProcessor.extractRemainingAfterStart(trimmed, startMatch);

      stateMachine.startSilenceTimer();

      if (remaining.isNotEmpty) {
        rawSpeechInSession = trimmed;
        await _handleListeningState(remaining);
      } else {
        rawSpeechInSession = '';
        liveTranscript = '';
        onNotify();
      }
      return;
    }

    if (!stateMachine.isWakeWordRequired) {
      final endMatch = await triggerMatcher.checkEndWord(trimmed);
      if (endMatch.isMatched) {
        liveTranscript = trimmed;
        await submitLiveTranscript(endMatch);
        return;
      }

      rawSpeechInSession = trimmed;
      liveTranscript = trimmed;
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '正在倾听...',
      );
      onNotify();
      stateMachine.startSilenceTimer();
      return;
    }

    onSpeechDecision?.call(
      forText: trimmed,
      llmDecision: '待机未唤醒',
      shouldReply: false,
      detail: '待机状态未匹配开始词/唤醒词',
    );
    scheduleUnmatchedSpeechFade();
  }

  Future<void> _handleListeningState(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (!settings.speakerVerifyWakeOnly &&
        !speakerVerificationPort.verifyOwnerSpeaker(
          contextHint: '提问内容',
          onRejected: (reason) {
            onSpeechDecision?.call(
              forText: text,
              llmDecision: '声纹拦截',
              shouldReply: false,
              detail: reason,
            );
            stateMachine.setStatus(AssistantStatus.idle, reason);
            scheduleUnmatchedSpeechFade();
          },
        )) {
      return;
    }

    if (stateMachine.isInContinuousMode &&
        await triggerMatcher.checkExitContinuousWord(trimmed)) {
      if (onExitContinuous != null) {
        await onExitContinuous!();
      }
      return;
    }

    final resetMatch = await triggerMatcher.checkResetWord(trimmed);
    if (resetMatch.isMatched) {
      liveTranscript = '';
      rawSpeechInSession = '';
      if (onStartNewSession != null) {
        await onStartNewSession!(playVoice: true);
      }
      return;
    }

    final oneShot = await triggerMatcher.extractOneShotCommand(trimmed);
    if (oneShot != null) {
      liveTranscript = '';
      rawSpeechInSession = '';
      stateMachine.cancelSilenceTimer();
      stateMachine.resetContinuousTimer();
      if (onPlayAcknowledgeBeep != null) {
        unawaited(onPlayAcknowledgeBeep!());
      }
      stateMachine.setStatus(
        AssistantStatus.thinking,
        '识别到新指令【${oneShot.promptContent}】，正在请求回复...',
      );
      await onSubmitLlm(oneShot.promptContent, isExplicitCommand: true);
      return;
    }

    final startMatch = await triggerMatcher.checkStartWord(trimmed);
    if (startMatch.isMatched) {
      liveTranscript = '';
      audioControlPort.resetStream();
      if (onPlayAcknowledgeBeep != null) {
        unawaited(onPlayAcknowledgeBeep!());
      }
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '重新听到开始词【${startMatch.matchedText}】，已清空前文，正在倾听新内容...（说“${settings.endWords.join("、")}”结束）',
      );
      stateMachine.resetSilenceTimer();
      stateMachine.resetContinuousTimer();

      final remaining =
          TranscriptProcessor.extractRemainingAfterStart(trimmed, startMatch);

      if (remaining.isNotEmpty) {
        rawSpeechInSession = trimmed;
        await _handleListeningState(remaining);
      } else {
        rawSpeechInSession = '';
        onNotify();
      }
      return;
    }

    if (audioControlPort.isAsrStreaming) {
      liveTranscript =
          TranscriptProcessor.mergeStreamingTranscript(liveTranscript, trimmed);
    } else {
      liveTranscript += (liveTranscript.isEmpty ? '' : ' ') + trimmed;
    }
    _emitTranscriptUpdated();
    onNotify();

    stateMachine.resetSilenceTimer();
    stateMachine.resetContinuousTimer();

    final endMatch = await triggerMatcher.checkEndWord(liveTranscript);
    if (endMatch.isMatched &&
        stateMachine.status == AssistantStatus.listeningContent &&
        !_disposed) {
      await submitLiveTranscript(endMatch);
    }
  }

  Future<void> submitLiveTranscript(TriggerMatchResult endMatch) async {
    if ((stateMachine.status != AssistantStatus.listeningContent &&
            stateMachine.status != AssistantStatus.idle) ||
        _disposed) {
      return;
    }
    stateMachine.cancelSilenceTimer();
    stateMachine.resetContinuousTimer();
    rawSpeechInSession = '';

    String promptContent = '';
    if (endMatch.startIndex >= 0 &&
        endMatch.startIndex <= liveTranscript.length) {
      promptContent = triggerMatcher
          .stripPunctuation(
            liveTranscript.substring(0, endMatch.startIndex),
          )
          .trim();
    } else {
      promptContent = triggerMatcher.stripEndWord(liveTranscript).trim();
    }

    liveTranscript = '';
    audioControlPort.flushBuffers(cooldownMs: 300);

    if (promptContent.isEmpty) {
      stateMachine.setStatus(AssistantStatus.idle, '只听到结束词，未识别到有效提问，返回待机');
      return;
    }

    if (onPlayAcknowledgeBeep != null) {
      unawaited(onPlayAcknowledgeBeep!());
    }
    stateMachine.setStatus(
      AssistantStatus.thinking,
      '识别到指令【$promptContent】，正在请求回复...',
    );
    onSpeechDecision?.call(
      forText: promptContent,
      llmDecision: '大模型判定中...',
      shouldReply: null,
      detail: '识别到指令【$promptContent】，已提交大模型',
    );
    unawaited(onSubmitLlm(promptContent, isExplicitCommand: true));
  }

  /// 主动触发激活唤醒（切入倾听态）
  Future<void> triggerWake({String? wakeWord}) async {
    final word = wakeWord ?? settings.startWord;
    isWakeWordMatched = true;
    audioControlPort.resetStream();
    if (onPlayAcknowledgeBeep != null) {
      unawaited(onPlayAcknowledgeBeep!());
    }
    stateMachine.setStatus(
      AssistantStatus.listeningContent,
      '收到唤醒指令【$word】，正在倾听内容...',
    );
    stateMachine.startSilenceTimer();
  }

  /// 调度未匹配语音自动淡出计时器（默认 4 秒）
  void scheduleUnmatchedSpeechFade({
    Duration duration = const Duration(seconds: 4),
  }) {
    isWakeWordMatched = false;
    _emitTranscriptUpdated();
    onNotify();

    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = Timer(duration, () {
      if (!isWakeWordMatched && stateMachine.status == AssistantStatus.idle) {
        lastRecognizedSpeech = '';
        emit(TranscriptUpdatedEvent(
          live: '',
          display: '',
          lastRecognized: '',
          isWakeWordMatched: false,
        ));
        onNotify();
      }
    });
  }

  /// 取消未匹配语音淡出计时器
  void cancelUnmatchedSpeechTimer() {
    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = null;
  }

  /// 清空转写缓冲区
  void clearTranscripts({bool clearLastRecognized = true}) {
    liveTranscript = '';
    rawSpeechInSession = '';
    isWakeWordMatched = false;
    if (clearLastRecognized) {
      lastRecognizedSpeech = '';
    }
  }

  /// 抽取当前未完成提问文本并清空暂存区
  String extractPendingSpeech() {
    final pending = rawSpeechInSession.isNotEmpty
        ? rawSpeechInSession
        : liveTranscript.trim();
    rawSpeechInSession = '';
    liveTranscript = '';
    return pending;
  }

  // ==================== 触发词与控制指令匹配快捷代理 ====================

  /// 检查开始词/唤醒词
  Future<TriggerMatchResult> checkStartWord(String candidate) =>
      triggerMatcher.checkStartWord(candidate);

  /// 检查结束词
  Future<TriggerMatchResult> checkEndWord(String candidate) =>
      triggerMatcher.checkEndWord(candidate);

  /// 检查重置/新起会话词
  Future<TriggerMatchResult> checkResetWord(String candidate) =>
      triggerMatcher.checkResetWord(candidate);

  /// 检查退出连续对话词
  Future<bool> checkExitContinuousWord(String candidate) =>
      triggerMatcher.checkExitContinuousWord(candidate);

  /// 提取唤醒词+提问指令一步达指令
  Future<ExtractedCommand?> extractOneShotCommand(String candidate) =>
      triggerMatcher.extractOneShotCommand(candidate);

  /// 截取开始词匹配位置之后的剩余文本
  String extractRemainingAfterStart(
    String text,
    TriggerMatchResult startMatch,
  ) =>
      TranscriptProcessor.extractRemainingAfterStart(text, startMatch);

  /// 提取包含结束词的转写流中的有效 Prompt 内容（剥离标点与结束词）
  String extractPromptContent(String fullText, TriggerMatchResult endMatch) {
    if (endMatch.startIndex >= 0 && endMatch.startIndex <= fullText.length) {
      return triggerMatcher
          .stripPunctuation(fullText.substring(0, endMatch.startIndex))
          .trim();
    }
    return triggerMatcher.stripEndWord(fullText).trim();
  }

  /// 是否为严格的纯停止口令
  bool isPureStopWord(String text) => pureStopWords.contains(text.trim());

  /// 文本是否包含打断停止类关键词
  bool containsStopWord(String text) {
    final clean = text.trim();
    for (final kw in stopKeywords) {
      if (clean.contains(kw)) return true;
    }
    return false;
  }

  /// 文本是否包含退下/退出对话关键词
  bool containsDismissWord(String text) {
    final clean = text.trim();
    if (clean.contains('退下')) return true;
    for (final exitWord in settings.exitContinuousWords) {
      final w = triggerMatcher.stripPunctuation(exitWord, all: true).trim();
      if (w.isNotEmpty && clean.contains(w)) return true;
    }
    return false;
  }

  /// 是否为严格的纯退下口令
  bool isPureDismissWord(String text) {
    final clean = text.trim();
    if (clean == '退下') return true;
    for (final exitWord in settings.exitContinuousWords) {
      final w = triggerMatcher.stripPunctuation(exitWord, all: true).trim();
      if (w.isNotEmpty && clean == w) return true;
    }
    return false;
  }

  // ==================== 两阶段 ASR 仲裁与流式合并 ====================

  /// 静态两阶段最终转写文本优选仲裁
  static String chooseFinalTranscript(String live, String finalText) =>
      TranscriptProcessor.chooseFinalTranscript(live, finalText);

  /// 静态流式增量文本重叠拼接合并
  static String mergeStreamingTranscript(String current, String incoming) =>
      TranscriptProcessor.mergeStreamingTranscript(current, incoming);

  /// 将流式增量识别文本合并入 [liveTranscript] 并返回合并后结果
  String updateStreamingTranscript(String incoming) {
    liveTranscript = mergeStreamingTranscript(liveTranscript, incoming);
    return liveTranscript;
  }

  /// 将离线复检最终文本与 [liveTranscript] 仲裁合并并更新 [liveTranscript]
  String updateFinalTranscript(String finalText) {
    liveTranscript = chooseFinalTranscript(liveTranscript, finalText);
    return liveTranscript;
  }

  /// 增量更新设置
  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
  }

  /// 销毁协调器
  void dispose() {
    _disposed = true;
    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = null;
  }
}
