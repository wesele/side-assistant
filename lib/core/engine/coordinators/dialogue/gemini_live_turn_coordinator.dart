import 'dart:async';

import '../../../models/app_settings.dart';
import '../../../models/assistant_status.dart';
import '../../../models/camera_capture_result.dart';
import '../../../platform/foundation_bridge.dart';
import '../../../ports/gemini_live_session_port.dart';
import '../../../ports/prompt_sound_port.dart';
import '../../../ports/session_message_port.dart';
import '../../engine_events.dart';
import 'dialogue_state_machine.dart';
import 'support/gemini_live_deferred_turn_manager.dart';
import 'support/gemini_live_idle_session_watcher.dart';
import 'support/gemini_live_tool_progress_helper.dart';
import 'support/local_playback_echo_guard.dart';
import 'transcript_trigger_coordinator.dart';

/// Gemini 3.8 Live 全双工轮次与消息气泡编排器
///
/// 负责将 [GeminiLiveSessionPort] 的实时音频流、双向转写字幕 (`inputTranscription` /
/// `outputTranscription`)、`interrupted` 瞬时打断及 `capture_photo` / `lightrag_query`
/// 工具调用与领域状态机 ([DialogueStateMachine])、会话存储 ([SessionMessagePort]) 无缝桥接。
/// 纯 Dart 实现，零 `dart:ui` / `package:flutter` 依赖。
class GeminiLiveTurnCoordinator {
  AppSettings settings;
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;
  final SessionMessagePort sessionMessagePort;
  final PromptSoundPort promptSoundService;
  final DialogueStateMachine stateMachine;
  final TranscriptTriggerCoordinator transcriptCoordinator;
  final Future<CameraCaptureResult> Function()? onCapturePhotoDirect;
  final Future<void> Function(String text)? onSpeakStatus;
  final Future<void> Function()? onStopSpeakStatus;
  final Future<void> Function()? onAutoNewSession;
  Duration toolProgressInterval;
  void Function({
    String? forText,
    required String llmDecision,
    bool? shouldReply,
    String? intent,
    String? detail,
  })? onSpeechDecision;
  final void Function(String thought)? onThoughtSummary;

  late GeminiLiveSessionPort liveSession;
  final GeminiLiveDeferredTurnManager _deferredManager;
  final GeminiLiveIdleSessionWatcher _idleWatcher =
      GeminiLiveIdleSessionWatcher();
  late final _localPlaybackGuard = LocalPlaybackEchoGuard(
    tts: transcriptCoordinator.ttsService,
    matcher: transcriptCoordinator.triggerMatcher,
  );

  String? _activeUserMsgId;
  String? _activeAssistantMsgId;
  int? _activeAssistantMsgIndex;
  String? _capturedImagePath;
  Uint8List? _capturedImageBytes;
  String _currentSpeakingReply = '';
  String _preToolReply = '';
  Timer? _toolProgressTimer;
  bool _pendingClientTextTurn = false;
  bool _currentTurnUnintended = false;
  bool _turnMessagesCreated = false;
  String _activeUserText = '';
  String _lastInterruptedUserText = '';
  DateTime? _lastInterruptedAt;

  GeminiLiveTurnCoordinator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    required this.sessionMessagePort,
    required this.promptSoundService,
    required this.stateMachine,
    required this.transcriptCoordinator,
    this.onCapturePhotoDirect,
    this.onSpeakStatus,
    this.onStopSpeakStatus,
    this.onAutoNewSession,
    Duration? toolProgressInterval,
    this.onSpeechDecision,
    this.onThoughtSummary,
    Duration deferredTurnTimeout = const Duration(seconds: 90),
    GeminiLiveSessionPort? liveSession,
    GeminiLiveDeferredTurnManager? deferredManager,
  })  : toolProgressInterval = toolProgressInterval ??
            Duration(
                seconds:
                    settings.openCodeProgressIntervalSeconds.clamp(1, 600)),
        _deferredManager = deferredManager ??
            GeminiLiveDeferredTurnManager(timeout: deferredTurnTimeout) {
    this.liveSession = liveSession ??
        (GeminiLiveSessionFactoryRegistry.defaultFactory?.call(settings) ??
            NullGeminiLiveSessionPort());
    _bindSessionCallbacks();
  }

  String get currentSpeakingReply => _currentSpeakingReply;
  bool get isTurnDeferred => _deferredManager.isTurnDeferred;
  bool get isToolProgressRunning =>
      _toolProgressTimer != null && _toolProgressTimer!.isActive;
  bool get isDeferredTimerActive => _deferredManager.isDeferredTimerActive;
  bool get lastInteractionInProgress =>
      _deferredManager.lastInteractionInProgress;
  Set<String> get pendingToolCallIds => _deferredManager.pendingToolCallIds;
  Duration get deferredTurnTimeout => _deferredManager.timeout;
  set deferredTurnTimeout(Duration val) => _deferredManager.timeout = val;
  bool get isIdleNewSessionTimerActive => _idleWatcher.isTimerActive;
  bool get _hasActiveTurn =>
      _activeUserMsgId != null ||
      _deferredManager.isTurnDeferred ||
      _deferredManager.lastInteractionInProgress ||
      isToolProgressRunning ||
      _pendingClientTextTurn ||
      liveSession.isSpeakingOutput;

  void trackPendingToolCall(String id) =>
      _deferredManager.trackPendingToolCall(id);
  void removePendingToolCall(String id) {
    _deferredManager.removePendingToolCall(id);
    _maybeEndDeferredTurn();
  }

  void _bindSessionCallbacks() {
    liveSession.onInputTranscription = _handleInputTranscription;
    liveSession.onOutputTranscription = _handleOutputTranscription;
    liveSession.onModelTurnStarted = _handleModelTurnStarted;
    liveSession.onTurnCompleted = _handleTurnCompleted;
    liveSession.onInterrupted = _handleInterrupted;
    liveSession.onStatusHintChanged = (hint) {
      if (!settings.isGeminiLiveMode) return;
      if (!liveSession.isActive &&
          stateMachine.status == AssistantStatus.listeningContent) {
        stateMachine.setStatus(AssistantStatus.idle, hint);
        return;
      }
      if (stateMachine.status == AssistantStatus.idle ||
          stateMachine.status == AssistantStatus.listeningContent) {
        stateMachine.setStatus(stateMachine.status, hint);
      }
    };
    liveSession.onCapturePhoto = _handleCapturePhotoTool;
    liveSession.onToolCall = _handleToolCallStatus;
    liveSession.onBackgroundSpeechDetected = _handleBackgroundSpeechDetected;
    liveSession.onThought = _handleThought;
    liveSession.onInteractionStatus = _handleInteractionStatus;
    liveSession.onToolCallsCancelled = _handleToolCallsCancelled;
  }

  void _handleThought(String thought) {
    if (!settings.isGeminiLiveMode) return;
    _idleWatcher.cancelIdle();
    debugPrint('[GeminiLiveTurnCoordinator] 收到深度思考内容: $thought');
    if (stateMachine.status != AssistantStatus.playing) {
      stateMachine.setStatus(
        AssistantStatus.thinking,
        'Gemini Live 正在思考...',
      );
    }
    onThoughtSummary?.call(thought);
    onNotify();
  }

  void _handleInteractionStatus(bool inProgress) {
    if (!settings.isGeminiLiveMode) return;
    _deferredManager.lastInteractionInProgress = inProgress;
    if (inProgress) {
      _idleWatcher.cancelIdle();
    } else {
      _maybeEndDeferredTurn();
    }
  }

  void _handleToolCallsCancelled(List<String> ids) {
    if (!settings.isGeminiLiveMode) return;
    _idleWatcher.cancelIdle();
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _deferredManager.removePendingToolCalls(ids);

    const cancelledHint = '工具调用已取消';
    stateMachine.setStatus(AssistantStatus.thinking, cancelledHint);

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      final bubbleText = _deferredManager.formatBubbleWithToolStatus(
        preToolReply: _preToolReply,
        statusDisplay: cancelledHint,
      );
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        bubbleText,
        isStreaming: true,
      );
    }
    onNotify();

    _maybeEndDeferredTurn();
  }

  void _maybeEndDeferredTurn() {
    if (_deferredManager.isTurnDeferred &&
        !_deferredManager.lastInteractionInProgress &&
        !_deferredManager.hasPendingToolCalls(
          isToolProgressRunning: isToolProgressRunning,
        ) &&
        _currentSpeakingReply.isEmpty) {
      _finalizeAndResetTurn(wasUnintended: false);
    }
  }

  void _ensureTurnMessagesCreated({String initialUserText = ''}) {
    if (_activeUserMsgId != null && _activeAssistantMsgId != null) return;
    final text = initialUserText.trim().isNotEmpty
        ? initialUserText.trim()
        : (transcriptCoordinator.liveTranscript.trim().isNotEmpty
            ? transcriptCoordinator.liveTranscript.trim()
            : '（语音输入）');
    _activeUserText = text;
    final pair = sessionMessagePort.appendUserAndPlaceholderMessage(
      text,
      imagePath: _capturedImagePath,
    );
    _activeUserMsgId = pair.userMsgId;
    _activeAssistantMsgId = pair.assistantMsgId;
    _activeAssistantMsgIndex = pair.assistantMsgIndex;
    _turnMessagesCreated = true;
  }

  void _handleInputTranscription(String text, {required bool isFinal}) {
    if (!settings.isGeminiLiveMode) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!_localPlaybackGuard.acceptInput(trimmed,
        hasActiveTurn: _activeUserMsgId != null)) return;

    if (_activeUserMsgId == null &&
        _lastInterruptedUserText.isNotEmpty &&
        _lastInterruptedAt != null &&
        DateTime.now().difference(_lastInterruptedAt!) <
            const Duration(milliseconds: 1500) &&
        trimmed == _lastInterruptedUserText) {
      return;
    }
    if (trimmed != _lastInterruptedUserText) {
      _lastInterruptedUserText = '';
    }

    if (_deferredManager.isTurnDeferred) {
      _finalizeAndResetTurn(wasUnintended: false);
    }
    _idleWatcher.cancelIdle();

    _activeUserText = trimmed;
    transcriptCoordinator.isWakeWordMatched = true;
    transcriptCoordinator.liveTranscript = trimmed;
    transcriptCoordinator.lastRecognizedSpeech = trimmed;
    emit(TranscriptUpdatedEvent(
      live: trimmed,
      display: trimmed,
      lastRecognized: trimmed,
      isWakeWordMatched: true,
      isFinal: isFinal,
    ));

    if (_currentTurnUnintended) {
      if (_activeUserMsgId != null) {
        sessionMessagePort.markUserTurnAsUnintended(
          userMsgId: _activeUserMsgId!,
          overrideText: _activeUserText,
        );
      }
      onNotify();
      return;
    }

    if (_activeUserMsgId == null) {
      _currentTurnUnintended = false;
      _ensureTurnMessagesCreated(initialUserText: trimmed);
    } else {
      sessionMessagePort.updateUserMessageContent(
        _activeUserMsgId!,
        trimmed,
      );
    }

    if (isFinal) {
      onSpeechDecision?.call(
        forText: trimmed,
        llmDecision: 'Gemini Live 全双工直通',
        shouldReply: true,
        intent: 'gemini_live',
        detail: 'Gemini 3.8 Live 实时音频流理解与回答',
      );
    }
    onNotify();
  }

  void _handleModelTurnStarted() {
    if (_localPlaybackGuard.isEchoTurn) return;
    _pendingClientTextTurn = false;
    if (_currentTurnUnintended) return;
    if (!settings.isGeminiLiveMode) return;
    _idleWatcher.cancelIdle();
    _ensureTurnMessagesCreated();
    stateMachine.setStatus(
      AssistantStatus.playing,
      'Gemini Live 正在回答...',
    );
    onNotify();
  }

  void _cancelToolProgressTimer() {
    _toolProgressTimer?.cancel();
    _toolProgressTimer = null;
  }

  void _stopLocalSpeakStatus() {
    unawaited(onStopSpeakStatus?.call());
  }

  void _handleOutputTranscription(
    String deltaText,
    String fullText, {
    required bool isFinal,
  }) {
    if (_localPlaybackGuard.isEchoTurn) return;
    _pendingClientTextTurn = false;
    if (_currentTurnUnintended) return;
    if (!settings.isGeminiLiveMode) return;
    _idleWatcher.cancelIdle();
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _preToolReply = '';
    _ensureTurnMessagesCreated();
    _currentSpeakingReply = fullText;

    if (stateMachine.status != AssistantStatus.playing) {
      stateMachine.setStatus(
        AssistantStatus.playing,
        'Gemini Live 正在回答...',
      );
    }

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      final combined = _deferredManager.combineWithAccumulated(fullText);
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        combined,
        isStreaming: !isFinal,
      );
    }
    onNotify();
  }

  void _handleInterrupted() {
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _deferredManager.cancelSafetyTimer();
    _deferredManager.isTurnDeferred = false;
    _preToolReply = '';
    if (!settings.isGeminiLiveMode) return;
    if (_pendingClientTextTurn && _currentSpeakingReply.isEmpty) {
      _pendingClientTextTurn = false;
      return;
    }
    _pendingClientTextTurn = false;

    final interruptedAssistantText =
        _deferredManager.combineWithAccumulated(_currentSpeakingReply.trim());

    if (interruptedAssistantText.isEmpty) {
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '已打断，请继续说话...',
      );
      _scheduleIdleNewSessionTimer();
      onNotify();
      return;
    }

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        interruptedAssistantText,
        isStreaming: false,
      );
    }
    _lastInterruptedUserText = _activeUserText;
    _lastInterruptedAt = DateTime.now();
    _currentSpeakingReply = '';
    _deferredManager.reset();
    _resetTurnTracking();
    unawaited(sessionMessagePort.syncCurrentSession(persist: true));
    stateMachine.setStatus(
      AssistantStatus.listeningContent,
      '已打断，请继续说话...',
    );
    _scheduleIdleNewSessionTimer();
    onNotify();
  }

  void _handleTurnCompleted() {
    if (_localPlaybackGuard.consumeEchoTurn()) return;
    _pendingClientTextTurn = false;
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _preToolReply = '';
    if (!settings.isGeminiLiveMode) return;
    final wasUnintended = _currentTurnUnintended;

    final shouldDefer = liveSession.isAdvancedMode &&
        !wasUnintended &&
        (_deferredManager.lastInteractionInProgress ||
            _deferredManager.hasPendingToolCalls(
              isToolProgressRunning: isToolProgressRunning,
            ));

    if (shouldDefer) {
      _markTurnDeferred();
      return;
    }

    _finalizeAndResetTurn(wasUnintended: wasUnintended);
  }

  void _markTurnDeferred() {
    _deferredManager.finalizeSegmentText(_currentSpeakingReply);
    if (_activeAssistantMsgId != null &&
        _activeAssistantMsgIndex != null &&
        _deferredManager.accumulatedAssistantText.isNotEmpty) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        _deferredManager.accumulatedAssistantText,
        isStreaming: true,
      );
    }
    _currentSpeakingReply = '';
    unawaited(sessionMessagePort.syncCurrentSession(persist: true));
    _deferredManager.markDeferred(
      onTimeout: () {
        if (_deferredManager.isTurnDeferred) {
          _finalizeAndResetTurn(wasUnintended: false);
        }
      },
    );

    stateMachine.setStatus(
      AssistantStatus.listeningContent,
      'Gemini 3.8 Live 全双工通话中，请直接说话',
    );
    stateMachine.resetContinuousTimer();
    onNotify();
  }

  void _finalizeAndResetTurn({required bool wasUnintended}) {
    _deferredManager.cancelSafetyTimer();
    _deferredManager.isTurnDeferred = false;
    final userMsgId = _activeUserMsgId;
    final imgPath = _capturedImagePath;
    final imgBytes = _capturedImageBytes;

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      final finalReply =
          _deferredManager.combineWithAccumulated(_currentSpeakingReply.trim());
      if (finalReply.isNotEmpty) {
        sessionMessagePort.updateAssistantMessageContent(
          _activeAssistantMsgId!,
          _activeAssistantMsgIndex!,
          finalReply,
          isStreaming: false,
        );
      }
    }

    _currentSpeakingReply = '';
    _deferredManager.reset();
    _resetTurnTracking();

    unawaited(() async {
      if (userMsgId != null &&
          ((imgPath != null && imgPath.isNotEmpty) ||
              (imgBytes != null && imgBytes.isNotEmpty))) {
        final persisted = await sessionMessagePort.persistImage(
          sessionId: sessionMessagePort.currentSessionId,
          messageId: userMsgId,
          sourcePath: imgPath,
          imageBytes: imgBytes,
        );
        if (persisted != null) {
          sessionMessagePort.updateMessageImagePath(userMsgId, persisted);
        }
      }
      await sessionMessagePort.syncCurrentSession(persist: true);
    }());

    if (wasUnintended) {
      stateMachine.setStatus(
        AssistantStatus.idle,
        '未检测到对话意图',
      );
    } else {
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        'Gemini 3.8 Live 全双工通话中，请直接说话',
      );
      stateMachine.resetContinuousTimer();
    }
    _scheduleIdleNewSessionTimer();
    onNotify();
  }

  void _handleBackgroundSpeechDetected(String detectedText, String reason) {
    _currentTurnUnintended = true;
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _deferredManager.reset();
    unawaited(liveSession.stopSpeaking());

    final rawDetected = detectedText.trim();
    final rawActive = _activeUserText.trim();
    final effectiveText = rawActive.isEmpty
        ? rawDetected
        : (rawDetected.length > rawActive.length ? rawDetected : rawActive);
    _activeUserText = effectiveText;

    if (_turnMessagesCreated && _activeUserMsgId != null) {
      sessionMessagePort.markUserTurnAsUnintended(
        userMsgId: _activeUserMsgId!,
        assistantPlaceholderId: _activeAssistantMsgId,
        overrideText: effectiveText,
      );
      _activeAssistantMsgId = null;
    } else if (effectiveText.isNotEmpty) {
      final msg = sessionMessagePort.appendUnintendedUserMessage(effectiveText);
      _activeUserMsgId = msg.id;
      _turnMessagesCreated = true;
    }

    onSpeechDecision?.call(
      forText: effectiveText,
      llmDecision: '无需回答 (背景信息)',
      shouldReply: false,
      intent: 'ignore',
      detail: reason.isNotEmpty
          ? 'Gemini Live 判定无交谈意图: $reason'
          : 'Gemini Live 判定无交谈意图，已记为背景信息',
    );

    stateMachine.setStatus(AssistantStatus.idle, '未检测到对话意图');
    unawaited(sessionMessagePort.syncCurrentSession(persist: true));
    onNotify();
  }

  Future<CameraCaptureResult?> _handleCapturePhotoTool() async {
    if (onCapturePhotoDirect == null) return null;
    _idleWatcher.cancelIdle();
    unawaited(promptSoundService.playShutterSound());
    stateMachine.setStatus(AssistantStatus.thinking, '正在调用相机拍摄现场画面...');
    _deferredManager.isCapturingPhoto = true;
    try {
      final res = await onCapturePhotoDirect!();
      _capturedImageBytes = res.imageBytes;
      _capturedImagePath = res.filePath;
      _ensureTurnMessagesCreated();
      if (_activeUserMsgId != null && res.filePath.isNotEmpty) {
        sessionMessagePort.updateMessageImagePath(
          _activeUserMsgId!,
          res.filePath,
        );
      }
      return res;
    } catch (_) {
      return null;
    } finally {
      _deferredManager.isCapturingPhoto = false;
      _maybeEndDeferredTurn();
    }
  }

  void _handleToolCallStatus(String toolName, String query) {
    _idleWatcher.cancelIdle();
    _ensureTurnMessagesCreated();
    final q = query.trim();
    final display = GeminiLiveToolProgressHelper.buildCallStatusDisplay(
      toolName: toolName,
      query: q,
      codeAgentProvider: settings.codeAgentProvider,
    );
    _preToolReply = _currentSpeakingReply.trim();
    _publishToolStatusBubble(display);

    if (toolName == 'invoke_opencode' || toolName == 'call_custom_tool') {
      final isAdvanced = liveSession.isAdvancedMode;
      final hasSpoken =
          _preToolReply.isNotEmpty || liveSession.isSpeakingOutput;
      if (!isAdvanced && !hasSpoken && onSpeakStatus != null) {
        unawaited(
            onSpeakStatus!(GeminiLiveToolProgressHelper.buildPreCallSpoken(
          toolName: toolName,
          query: q,
          codeAgentProvider: settings.codeAgentProvider,
        )));
      }
      _cancelToolProgressTimer();
      _toolProgressTimer = GeminiLiveToolProgressHelper.startProgressTimer(
        interval: toolProgressInterval,
        toolName: toolName,
        query: q,
        getCodeAgentProvider: () => settings.codeAgentProvider,
        shouldSpeak: () =>
            !isAdvanced &&
            !liveSession.isSpeakingOutput &&
            onSpeakStatus != null,
        onPublish: _publishToolStatusBubble,
        onSpeak: (spoken) => unawaited(onSpeakStatus!(spoken)),
      );
    }
  }

  void _publishToolStatusBubble(String display) {
    final bubbleText = _deferredManager.formatBubbleWithToolStatus(
      preToolReply: _preToolReply,
      statusDisplay: display,
    );
    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        bubbleText,
        isStreaming: true,
      );
    }
    stateMachine.setStatus(AssistantStatus.thinking, display);
    onNotify();
  }

  void _resetTurnTracking() {
    _localPlaybackGuard.consumeEchoTurn();
    _cancelToolProgressTimer();
    _preToolReply = '';
    _pendingClientTextTurn = false;
    _currentTurnUnintended = false;
    _turnMessagesCreated = false;
    _activeUserText = '';
    _activeUserMsgId = null;
    _activeAssistantMsgId = null;
    _activeAssistantMsgIndex = null;
    _capturedImagePath = null;
    _capturedImageBytes = null;
  }

  /// 接收麦克风实时 16kHz PCM 采样并直推 Gemini Live
  void feedAudioSamples(Float32List samples) {
    if (!settings.isGeminiLiveMode) return;
    liveSession.feedAudioSamples(_localPlaybackGuard.guardUplink(samples));
  }

  void _resetLocalTurnState() {
    _cancelToolProgressTimer();
    _stopLocalSpeakStatus();
    _deferredManager.reset();
    _resetTurnTracking();
    _currentSpeakingReply = '';
  }

  void _scheduleIdleNewSessionTimer() => _idleWatcher.scheduleIdle(
        settings: settings,
        hasActiveTurn: () => _hasActiveTurn,
        sessionMessagePort: sessionMessagePort,
        liveSession: liveSession,
        stateMachine: stateMachine,
        resetLocalTurnState: _resetLocalTurnState,
        onAutoNewSession: onAutoNewSession,
      );

  /// 麦克风常驻监听启停状态联动
  Future<void> onMicListeningChanged(bool isListening) async {
    if (!settings.isGeminiLiveMode) return;
    await _idleWatcher.handleMicChanged(
      isListening: isListening,
      liveSession: liveSession,
      sessionMessagePort: sessionMessagePort,
      stateMachine: stateMachine,
      resetLocalTurnState: _resetLocalTurnState,
      onAutoNewSession: onAutoNewSession,
      onScheduleIdle: _scheduleIdleNewSessionTimer,
    );
  }

  /// 发送直接文本或附带图片消息至 Gemini Live 会话
  Future<void> sendClientText(
    String userText, {
    Uint8List? preCapturedImageBytes,
    String? preCapturedImagePath,
  }) async {
    final text = userText.trim();
    if (text.isEmpty) return;

    _idleWatcher.cancelIdle();
    if (_deferredManager.isTurnDeferred) {
      _finalizeAndResetTurn(wasUnintended: false);
    } else {
      _resetTurnTracking();
    }
    _capturedImageBytes = preCapturedImageBytes;
    _capturedImagePath = preCapturedImagePath;
    _ensureTurnMessagesCreated(initialUserText: text);
    _pendingClientTextTurn = true;

    stateMachine.setStatus(AssistantStatus.thinking, '正在发送至 Gemini Live...');
    await liveSession.sendClientText(
      text,
      imageBytes: preCapturedImageBytes,
      imagePath: preCapturedImagePath,
    );
  }

  /// 会话重置或切换时同步上下文
  Future<void> onSessionChanged({required bool resetSession}) async {
    _idleWatcher.cancelIdle();
    _resetLocalTurnState();
    if (!settings.isGeminiLiveMode) return;
    await liveSession.syncSessionContext(
      sessionMessagePort.messages,
      resetSession: resetSession,
    );
    if (_idleWatcher.micSessionOpen && liveSession.isActive) {
      _scheduleIdleNewSessionTimer();
    }
  }

  Future<void> stopSpeaking() async {
    _resetLocalTurnState();
    await liveSession.stopSpeaking();
    if (_idleWatcher.micSessionOpen && liveSession.isActive) {
      _scheduleIdleNewSessionTimer();
    }
  }

  /// 试听指定的 Gemini Live 原生音色
  Future<void> previewVoice({required String voice, String? text}) =>
      liveSession.previewVoice(voice: voice, text: text);

  void updateSettings(AppSettings newSettings) {
    final wasLive = settings.isGeminiLiveMode;
    settings = newSettings;
    toolProgressInterval = Duration(
      seconds: newSettings.openCodeProgressIntervalSeconds.clamp(1, 600),
    );
    liveSession.applySettings(newSettings);
    if (wasLive && !newSettings.isGeminiLiveMode) {
      _idleWatcher.micSessionOpen = false;
      _idleWatcher.cancelIdle();
      _resetLocalTurnState();
      unawaited(liveSession.disconnect());
    } else if (newSettings.isGeminiLiveMode && _idleWatcher.micSessionOpen) {
      if (newSettings.geminiLiveIdleNewSessionSeconds <= 0) {
        _idleWatcher.cancelIdle();
      } else if (!_hasActiveTurn) {
        _scheduleIdleNewSessionTimer();
      }
    }
  }

  void dispose() {
    _idleWatcher.dispose();
    _resetLocalTurnState();
    liveSession.onBackgroundSpeechDetected = null;
    liveSession.onThought = null;
    liveSession.onInteractionStatus = null;
    liveSession.onToolCallsCancelled = null;
    liveSession.dispose();
  }
}
