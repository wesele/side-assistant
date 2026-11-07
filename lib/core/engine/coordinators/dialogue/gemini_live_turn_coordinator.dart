import 'dart:async';
import 'dart:typed_data';

import '../../../models/app_settings.dart';
import '../../../models/assistant_status.dart';
import '../../../models/camera_capture_result.dart';
import '../../../ports/gemini_live_session_port.dart';
import '../../../ports/prompt_sound_port.dart';
import '../../engine_events.dart';
import '../session_coordinator.dart';
import 'dialogue_state_machine.dart';
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
  final void Function({
    String? forText,
    required String llmDecision,
    bool? shouldReply,
    String? intent,
    String? detail,
  })? onSpeechDecision;

  late GeminiLiveSessionPort liveSession;

  String? _activeUserMsgId;
  String? _activeAssistantMsgId;
  int? _activeAssistantMsgIndex;
  String? _capturedImagePath;
  Uint8List? _capturedImageBytes;
  String _currentSpeakingReply = '';
  bool _pendingClientTextTurn = false;
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
    this.onSpeechDecision,
    GeminiLiveSessionPort? liveSession,
  }) {
    this.liveSession = liveSession ??
        (GeminiLiveSessionFactoryRegistry.defaultFactory?.call(settings) ??
            NullGeminiLiveSessionPort());
    _bindSessionCallbacks();
  }

  String get currentSpeakingReply => _currentSpeakingReply;

  void _bindSessionCallbacks() {
    liveSession.onInputTranscription = _handleInputTranscription;
    liveSession.onOutputTranscription = _handleOutputTranscription;
    liveSession.onModelTurnStarted = _handleModelTurnStarted;
    liveSession.onTurnCompleted = _handleTurnCompleted;
    liveSession.onInterrupted = _handleInterrupted;
    liveSession.onStatusHintChanged = (hint) {
      if (!settings.isGeminiLiveMode) return;
      if (stateMachine.status == AssistantStatus.idle ||
          stateMachine.status == AssistantStatus.listeningContent) {
        stateMachine.setStatus(stateMachine.status, hint);
      }
    };
    liveSession.onCapturePhoto = _handleCapturePhotoTool;
    liveSession.onToolCall = _handleToolCallStatus;
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
  }

  void _handleInputTranscription(String text, {required bool isFinal}) {
    if (!settings.isGeminiLiveMode) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

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

    if (_activeUserMsgId == null) {
      _ensureTurnMessagesCreated(initialUserText: trimmed);
    } else if (sessionMessagePort is SessionCoordinator) {
      (sessionMessagePort as SessionCoordinator).updateUserMessageContent(
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
    _pendingClientTextTurn = false;
    if (!settings.isGeminiLiveMode) return;
    _ensureTurnMessagesCreated();
    stateMachine.setStatus(
      AssistantStatus.playing,
      'Gemini Live 正在回答...',
    );
    onNotify();
  }

  void _handleOutputTranscription(
    String deltaText,
    String fullText, {
    required bool isFinal,
  }) {
    _pendingClientTextTurn = false;
    if (!settings.isGeminiLiveMode) return;
    _ensureTurnMessagesCreated();
    _currentSpeakingReply = fullText;

    if (stateMachine.status != AssistantStatus.playing) {
      stateMachine.setStatus(
        AssistantStatus.playing,
        'Gemini Live 正在回答...',
      );
    }

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        fullText,
        isStreaming: !isFinal,
      );
    }
    onNotify();
  }

  void _handleInterrupted() {
    if (!settings.isGeminiLiveMode) return;
    if (_pendingClientTextTurn && _currentSpeakingReply.isEmpty) {
      _pendingClientTextTurn = false;
      return;
    }
    _pendingClientTextTurn = false;

    if (_currentSpeakingReply.trim().isEmpty) {
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '已打断，请继续说话...',
      );
      onNotify();
      return;
    }

    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        _currentSpeakingReply,
        isStreaming: false,
      );
    }
    _lastInterruptedUserText = _activeUserText;
    _lastInterruptedAt = DateTime.now();
    _currentSpeakingReply = '';
    _resetTurnTracking();
    unawaited(sessionMessagePort.syncCurrentSession(persist: true));
    stateMachine.setStatus(
      AssistantStatus.listeningContent,
      '已打断，请继续说话...',
    );
    onNotify();
  }

  void _handleTurnCompleted() {
    _pendingClientTextTurn = false;
    if (!settings.isGeminiLiveMode) return;
    final userMsgId = _activeUserMsgId;
    final imgPath = _capturedImagePath;
    final imgBytes = _capturedImageBytes;
    _currentSpeakingReply = '';
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

    stateMachine.setStatus(
      AssistantStatus.listeningContent,
      'Gemini 3.8 Live 全双工通话中，请直接说话',
    );
    stateMachine.resetContinuousTimer();
    onNotify();
  }

  Future<CameraCaptureResult?> _handleCapturePhotoTool() async {
    if (onCapturePhotoDirect == null) return null;
    unawaited(promptSoundService.playShutterSound());
    stateMachine.setStatus(AssistantStatus.thinking, '正在调用相机拍摄现场画面...');
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
    }
  }

  void _handleToolCallStatus(String toolName, String query) {
    _ensureTurnMessagesCreated();
    final q = query.trim();
    final String display;
    if (toolName == 'capture_photo') {
      display = '正在调用相机拍照...';
    } else if (toolName == 'call_custom_tool') {
      display = q.isNotEmpty ? '正在调用工具：$q...' : '正在执行扩展工具...';
    } else if (toolName == 'invoke_opencode') {
      display =
          q.isNotEmpty ? '正在调用 OpenCode 构建工具：$q...' : '正在调用 OpenCode 构建工具...';
    } else {
      display = q.isNotEmpty ? '正在检索：$q...' : '正在查询...';
    }
    if (_activeAssistantMsgId != null && _activeAssistantMsgIndex != null) {
      sessionMessagePort.updateAssistantMessageContent(
        _activeAssistantMsgId!,
        _activeAssistantMsgIndex!,
        display,
        isStreaming: true,
      );
    }
  }

  void _resetTurnTracking() {
    _pendingClientTextTurn = false;
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
    liveSession.feedAudioSamples(samples);
  }

  /// 麦克风常驻监听启停状态联动
  Future<void> onMicListeningChanged(bool isListening) async {
    if (!settings.isGeminiLiveMode) return;
    if (isListening) {
      stateMachine.enterContinuousMode();
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '正在连接 Gemini 3.8 Live...',
      );
      final ok = await liveSession.connect();
      if (ok) {
        stateMachine.setStatus(
          AssistantStatus.listeningContent,
          'Gemini 3.8 Live 全双工通话中，请直接说话',
        );
      } else {
        stateMachine.setStatus(
          AssistantStatus.idle,
          liveSession.lastError ?? 'Gemini Live 连接失败',
        );
      }
    } else {
      _resetTurnTracking();
      await liveSession.disconnect();
      stateMachine.setStatus(AssistantStatus.idle, '话筒已静音');
    }
  }

  /// 发送直接文本或附带图片消息至 Gemini Live 会话
  Future<void> sendClientText(
    String userText, {
    Uint8List? preCapturedImageBytes,
    String? preCapturedImagePath,
  }) async {
    final text = userText.trim();
    if (text.isEmpty) return;

    _resetTurnTracking();
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
    _resetTurnTracking();
    _currentSpeakingReply = '';
    if (!settings.isGeminiLiveMode) return;
    await liveSession.syncSessionContext(
      sessionMessagePort.messages,
      resetSession: resetSession,
    );
  }

  Future<void> stopSpeaking() async {
    _currentSpeakingReply = '';
    _resetTurnTracking();
    await liveSession.stopSpeaking();
  }

  /// 试听指定的 Gemini Live 原生音色
  Future<void> previewVoice({
    required String voice,
    String? text,
  }) =>
      liveSession.previewVoice(
        voice: voice,
        text: text,
      );

  void updateSettings(AppSettings newSettings) {
    final wasLive = settings.isGeminiLiveMode;
    settings = newSettings;
    liveSession.applySettings(newSettings);
    if (wasLive && !newSettings.isGeminiLiveMode) {
      _resetTurnTracking();
      unawaited(liveSession.disconnect());
    }
  }

  void dispose() {
    _resetTurnTracking();
    liveSession.dispose();
  }
}
