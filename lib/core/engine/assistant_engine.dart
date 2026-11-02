// ignore_for_file: annotate_overrides
import 'dart:async';

import '../constants/app_constants.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/device_options.dart';
import '../platform/foundation_bridge.dart';
import '../ports/asr_port.dart';
import '../ports/assistant_driver_port.dart';
import '../platform/linux/linux_hardware_adapter.dart';
import '../ports/camera_port.dart';
import 'support/diagnostic_self_test_runner.dart';
import '../ports/chat_repository.dart';
import '../ports/llm_port.dart';
import '../ports/tts_port.dart';
import 'support/transcript_processor.dart';
import 'session_manager.dart';
import 'coordinators/dialogue_intent_coordinator.dart';
import 'coordinators/session_coordinator.dart';
import 'coordinators/voice_pipeline_coordinator.dart';
import 'engine_events.dart';

export 'coordinators/dialogue_intent_coordinator.dart';
export 'coordinators/session_coordinator.dart';
export 'coordinators/voice_pipeline_coordinator.dart';
export 'engine_events.dart';
export '../models/assistant_status.dart';
export '../ports/camera_port.dart';
export '../ports/assistant_driver_port.dart' show CameraCaptureResult;

/// 随身助理纯 Dart 领域核心引擎 (Layer 2 Application Core & Domain Engine)
///
/// 采用六边形架构与中介者模式 (Mediator Pattern)，作为顶层门面组合协调三大高内聚协调器：
/// - [VoicePipelineCoordinator]: 声学采集、VAD 检测、两阶段 ASR 仲裁与声纹鉴权；
/// - [DialogueIntentCoordinator]: 对话状态机、LLM 流式调用与工具派发、TTS 与即时打断；
/// - [SessionCoordinator]: 多会话生命周期 CRUD、增量消息维护与持久化/HTML 导出。
///
/// 框架无关（Framework-Agnostic），零 Flutter UI / `dart:ui` 依赖。
/// 对外完整实现 [AssistantDriverPort] 驱动契约，保持 100% 向后兼容。
class AssistantEngine extends ChangeNotifier implements AssistantDriverPort {
  final StreamController<AssistantEngineEvent> _eventController =
      StreamController<AssistantEngineEvent>.broadcast();
  Stream<AssistantEngineEvent> get events => _eventController.stream;

  AppSettings _settings;
  bool _disposed = false;

  late final SessionCoordinator _sessionCoordinator;
  late final VoicePipelineCoordinator _voiceCoordinator;
  late final DialogueIntentCoordinator _dialogueCoordinator;

  CameraPort? _cameraService;
  DriverServerPort? _driverServer;

  bool _isSelfTesting = false;
  final List<String> _selfTestLogs = [];
  bool _isQuickCapturing = false;
  bool _isNanoConnecting = false;

  AssistantEngine({
    required AppSettings settings,
    ChatRepository? chatHistoryService,
    LlmPort? injectedLlmService,
    CameraPort? cameraService,
    bool enableDriverServer = false,
    SessionCoordinator? sessionCoordinator,
    VoicePipelineCoordinator? voiceCoordinator,
    DialogueIntentCoordinator? dialogueCoordinator,
  }) : _settings = settings {
    _cameraService = cameraService;

    // 1. 装配 SessionCoordinator
    _sessionCoordinator = sessionCoordinator ??
        SessionCoordinator(
          emit: _emit,
          onNotify: notifyListeners,
          chatHistoryService: chatHistoryService,
        );

    // 2. 装配 VoicePipelineCoordinator
    _voiceCoordinator = voiceCoordinator ??
        VoicePipelineCoordinator(
          settings: _settings,
          emit: _emit,
          onNotify: notifyListeners,
        );

    // 3. 装配 DialogueIntentCoordinator
    _dialogueCoordinator = dialogueCoordinator ??
        DialogueIntentCoordinator(
          settings: _settings,
          emit: _emit,
          onNotify: notifyListeners,
          audioControlPort: _voiceCoordinator,
          speakerVerificationPort: _voiceCoordinator,
          sessionMessagePort: _sessionCoordinator,
          onCapturePhotoDirect: () => this.cameraService.capturePhoto(),
          llmService: injectedLlmService,
        );

    // 连接 Voice 与 Dialogue 回调总线
    _voiceCoordinator.onRecognizedText ??=
        (text) => _dialogueCoordinator.processRecognizedText(text);
    _voiceCoordinator.onPartialTranscript ??=
        (text) => _dialogueCoordinator.processPartialTranscript(text);
    _voiceCoordinator.onFinalTranscript ??=
        (text) => _dialogueCoordinator.processFinalTranscript(text);
    _voiceCoordinator.onManualRecordingRecognized ??=
        (text) => _dialogueCoordinator.sendDirectUserMessage(text);
    _voiceCoordinator.isStandbyMode ??=
        () => _dialogueCoordinator.status == AssistantStatus.idle;
    _voiceCoordinator.isPlayingMode ??=
        () => _dialogueCoordinator.status == AssistantStatus.playing;

    _setupCameraListeners();

    if (enableDriverServer) {
      final factory = DriverServerFactoryRegistry.defaultFactory;
      if (factory != null) {
        _driverServer ??= factory(this);
        unawaited(_driverServer!.start());
      }
    }

    unawaited(
      LinuxHardwareService.setOutputVolume(
        _settings.playbackVolume,
        outputDeviceId: _settings.audioOutputDeviceId,
      ),
    );
    unawaited(loadChatHistory());
  }

  void _emit(AssistantEngineEvent event) {
    if (!_disposed && !_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  // ---- 协调器访问器 ----
  SessionCoordinator get sessionCoordinator => _sessionCoordinator;
  VoicePipelineCoordinator get voiceCoordinator => _voiceCoordinator;
  DialogueIntentCoordinator get dialogueCoordinator => _dialogueCoordinator;

  // ---- 驱动层契约属性访问器 (AssistantDriverPort) ----

  @override
  AssistantStatus get status => _dialogueCoordinator.status;

  @override
  String get statusHint => _dialogueCoordinator.statusHint;

  @override
  String get liveTranscript => _dialogueCoordinator.liveTranscript;

  @override
  String get displayTranscript => _dialogueCoordinator.displayTranscript;

  @override
  String get lastRecognizedSpeech => _dialogueCoordinator.lastRecognizedSpeech;

  @override
  bool get isWakeWordMatched => _dialogueCoordinator.isWakeWordMatched;

  @override
  bool get isInContinuousMode => _dialogueCoordinator.isInContinuousMode;

  @override
  bool get isMicListening => _voiceCoordinator.isMicListening;

  @override
  bool get isManualRecording => _voiceCoordinator.isManualRecording;

  @override
  double get micLevel => _voiceCoordinator.micLevel;

  @override
  double get micDbfs => _voiceCoordinator.micDbfs;

  @override
  bool get vadDetected => _voiceCoordinator.vadDetected;

  @override
  bool get isMicTesting => _voiceCoordinator.isMicTesting;

  @override
  String get micTestText => _voiceCoordinator.micTestText;

  @override
  List<Map<String, dynamic>> get micTestHistory =>
      _voiceCoordinator.micTestHistory;

  @override
  AppSettings get settings => _settings;
  set settings(AppSettings val) => _settings = val;

  @override
  int get enrolledSpeakerCount => _voiceCoordinator.enrolledSpeakerCount;

  @override
  bool get hasEnrolledOwner => _voiceCoordinator.hasEnrolledOwner;

  @override
  String get speakerModelLabel => _voiceCoordinator.speakerModelLabel;

  @override
  String? get lastEnrollError => _voiceCoordinator.lastEnrollError;

  bool get isEnrollingSpeaker => _voiceCoordinator.isEnrolling;

  @override
  String get currentSessionId => _sessionCoordinator.currentSessionId;

  @override
  List<ChatMessage> get messages => _sessionCoordinator.messages;

  @override
  List<ChatSession> get sessions => _sessionCoordinator.sessions;

  @override
  bool get isSelfTesting => _isSelfTesting;

  @override
  List<String> get selfTestLogs => List.unmodifiable(_selfTestLogs);

  @override
  String get activeAudioInputDeviceLabel =>
      _voiceCoordinator.activeAudioInputDeviceLabel;

  @override
  bool get isQuickCapturing =>
      _isQuickCapturing || isNanoConnecting || isNanoCapturing;

  // ---- 遗留子服务兼容代理 (向后兼容 AssistantController & bin/linux_server.dart) ----

  AsrPort get asrService => _voiceCoordinator.asrService;
  TtsPort get ttsService => _dialogueCoordinator.ttsService;
  VoiceListeningPort get voiceService =>
      _voiceCoordinator.voiceListeningService;
  SpeakerVerifierPort get speakerVerificationService =>
      _voiceCoordinator.speakerVerificationService;
  TargetSpeakerExtractionPort get targetSpeakerExtractionService =>
      _voiceCoordinator.targetSpeakerExtractionService;
  SessionManager get sessionManager => _sessionCoordinator.sessionManager;
  ChatRepository get chatHistoryService =>
      _sessionCoordinator.chatHistoryService;
  LlmPort get llmService => _dialogueCoordinator.llmService;
  int get acknowledgeBeepCount => _dialogueCoordinator.acknowledgeBeepCount;
  DriverServerPort? get driverServer => _driverServer;

  // ---- 相机子系统门面 ----

  void _setupCameraListeners() {
    _cameraService?.setNanoStateListeners(
      onBatteryUpdate: (percent, charging) => notifyListeners(),
      onCaptureStateChanged: (_) => notifyListeners(),
    );
  }

  CameraPort get cameraService {
    if (_cameraService == null) {
      final factory = CameraPortRegistry.defaultFactory;
      if (factory != null) {
        _cameraService = factory(_settings);
      }
      _setupCameraListeners();
    }
    return _cameraService ?? const _DummyCameraPort();
  }

  bool get isCameraOpen => _cameraService?.isCameraOpen ?? false;
  bool get isNanoConnected => _cameraService?.isNanoConnected ?? false;
  bool get isNanoConnecting =>
      _isNanoConnecting || (_cameraService?.isNanoConnecting ?? false);
  bool get isNanoCameraMode =>
      _settings.captureSource == AppConstants.captureSourceNano;
  int get nanoBatteryPercent => _cameraService?.nanoBatteryPercent ?? -1;
  bool get isNanoCharging => _cameraService?.isNanoCharging ?? false;
  bool get isNanoCapturing => _cameraService?.isNanoCapturing ?? false;

  bool get isWakeWordRequired => _dialogueCoordinator.isWakeWordRequired;
  String get statusShortLabel => _dialogueCoordinator.statusShortLabel;

  // ---- 对话交互控制 (AssistantDriverPort) ----

  @override
  Future<void> simulateUserInput(String text) =>
      _dialogueCoordinator.simulateUserInput(text);

  @override
  Future<void> sendDirectUserMessage(String text) =>
      _dialogueCoordinator.sendDirectUserMessage(text);

  @override
  Future<void> sendTextMessage(String text) =>
      _dialogueCoordinator.sendTextMessage(text);

  Future<void> processRecognizedText(String recognizedText) =>
      _dialogueCoordinator.processRecognizedText(recognizedText);

  Future<void> processPartialTranscript(String partialText) =>
      _dialogueCoordinator.processPartialTranscript(partialText);

  Future<void> processFinalTranscript(String finalText) =>
      _dialogueCoordinator.processFinalTranscript(finalText);

  Future<void> triggerWake({String? wakeWord}) =>
      _dialogueCoordinator.triggerWake(wakeWord: wakeWord);

  Future<void> resetToIdle() => _dialogueCoordinator.resetToIdle();

  Future<void> playAcknowledgeBeep() =>
      _dialogueCoordinator.playAcknowledgeBeep();

  @override
  Future<void> stopSpeaking() => _dialogueCoordinator.stopSpeaking();

  @override
  Future<void> speakImmediate(String text) =>
      _dialogueCoordinator.speakImmediate(text);

  @override
  Future<void> previewVoice({String? voice, String? text}) =>
      _dialogueCoordinator.previewVoice(voice: voice, text: text);

  // ---- 会话管理控制 (AssistantDriverPort) ----

  Future<void> loadChatHistory() => _sessionCoordinator.loadChatHistory();

  @override
  Future<void> switchSession(String sessionId) =>
      _dialogueCoordinator.switchSession(sessionId);

  @override
  Future<void> renameSession(String sessionId, String newTitle) =>
      _sessionCoordinator.renameSession(sessionId, newTitle);

  @override
  Future<void> deleteSession(String sessionId) async {
    final wasCurrent = await _sessionCoordinator.deleteSession(sessionId);
    if (wasCurrent) {
      await _dialogueCoordinator.startNewSession(playVoice: false);
    }
  }

  @override
  Future<void> clearAllHistory() async {
    await _sessionCoordinator.clearAllHistory();
    await _dialogueCoordinator.startNewSession(playVoice: false);
  }

  @override
  Future<void> startNewSession({bool playVoice = true}) =>
      _dialogueCoordinator.startNewSession(playVoice: playVoice);

  @override
  Future<String> exportChatHistoryHtml() =>
      _sessionCoordinator.exportChatHistoryHtml();

  Future<String> exportAllHistoryToHtml() =>
      _sessionCoordinator.exportAllHistoryToHtml();

  // ---- 视觉与多模态控制 (AssistantDriverPort) ----

  @override
  Future<CameraCaptureResult> capturePhotoDirect() async {
    return await cameraService.capturePhoto();
  }

  @override
  Future<void> captureAndAskAboutScene({
    String question = '这是什么，介绍一下',
  }) async {
    if (_isQuickCapturing) {
      debugPrint('[AssistantEngine] 正在抓拍中，忽略重复点击');
      return;
    }

    _isQuickCapturing = true;
    notifyListeners();

    try {
      await _dialogueCoordinator.stopSpeaking();
      _voiceCoordinator.flushBuffers(cooldownMs: 300);
      _dialogueCoordinator.setStatus(AssistantStatus.thinking, '正在抓拍画面...');
      unawaited(_dialogueCoordinator.promptSoundService.playShutterSound());

      final captureResult = await cameraService.capturePhoto();
      if (captureResult.imageBytes.isEmpty) {
        throw Exception('未获取到有效画面');
      }

      _isQuickCapturing = false;
      notifyListeners();

      await _dialogueCoordinator.submitToLlm(
        question,
        preCapturedImageBytes: captureResult.imageBytes,
        preCapturedImagePath: captureResult.filePath,
      );
    } catch (e, st) {
      debugPrint('[AssistantEngine] 一键抓拍失败: $e');
      _emit(EngineErrorEvent('一键抓拍失败: $e', errorObject: e, stackTrace: st));
      _isQuickCapturing = false;
      notifyListeners();
      _dialogueCoordinator.setStatus(AssistantStatus.idle, '抓拍失败：$e');
      try {
        await _dialogueCoordinator.speakImmediate('抓拍失败，请检查相机连接');
      } catch (_) {}
    } finally {
      _isQuickCapturing = false;
    }
  }

  Future<void> toggleNanoConnection() async {
    if (_isNanoConnecting) return;
    _isNanoConnecting = true;
    notifyListeners();

    try {
      await cameraService.toggleNanoConnection(_settings);
    } catch (e) {
      debugPrint('[AssistantEngine] 切换 Nano 蓝牙连接状态异常: $e');
    } finally {
      _isNanoConnecting = false;
      notifyListeners();
    }
  }

  // ---- 语音管线与声卡控制 (AssistantDriverPort) ----

  @override
  Future<void> startManualRecording() =>
      _voiceCoordinator.startManualRecording();

  @override
  Future<void> stopManualRecording() => _voiceCoordinator.stopManualRecording();

  @override
  Future<void> toggleMicListening() async {
    await _voiceCoordinator.toggleContinuousListening();
    if (!_voiceCoordinator.isMicListening) {
      _dialogueCoordinator.exitContinuousMode(byUser: false);
    }
  }

  @override
  Future<void> setPlaybackVolume(int volume) async {
    final clamped = volume.clamp(0, 150);
    _settings.playbackVolume = clamped;
    await _settings.save();
    await LinuxHardwareService.setOutputVolume(
      clamped,
      outputDeviceId: _settings.audioOutputDeviceId,
    );
    notifyListeners();
  }

  @override
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) =>
      _voiceCoordinator.setMicTestMode(enabled, clear: clear);

  @override
  Future<String?> transcribeAudioFile(
    String path, {
    bool isStandbyWakeCheck = false,
  }) =>
      _voiceCoordinator.transcribeAudioFile(
        path,
        isStandbyWakeCheck: isStandbyWakeCheck,
      );

  @override
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) =>
      _voiceCoordinator.getRecentAudioSnippet(seconds: seconds);

  @override
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) =>
      _voiceCoordinator.enrollOwnerSpeaker(samples: samples);

  @override
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) =>
      _voiceCoordinator.recordAndEnrollOwnerSpeaker(seconds: seconds);

  @override
  Future<void> clearOwnerSpeaker() => _voiceCoordinator.clearOwnerSpeaker();

  @override
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity({
    double seconds = 3.0,
  }) =>
      _voiceCoordinator.recordAndTestOwnerSpeakerSimilarity(seconds: seconds);

  @override
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity({
    Float32List? samples,
  }) =>
      _voiceCoordinator.testOwnerSpeakerSimilarity(samples: samples);

  @override
  Future<String> testGeminiAsrConnection({String? apiKey, String? model}) =>
      _voiceCoordinator.testGeminiAsrConnection(apiKey: apiKey, model: model);

  @override
  Future<void> processAudioFile(String filePath) async {
    try {
      final text = await _voiceCoordinator.transcribeAudioFile(filePath);
      if (text != null && text.isNotEmpty) {
        await _dialogueCoordinator.processRecognizedText(text);
      }
    } catch (_) {}
  }

  Future<List<AudioInputDeviceOption>> listAudioInputDevices() =>
      _voiceCoordinator.listInputDevices();

  @override
  Future<void> setAudioInputDevice(String id, String label) =>
      _voiceCoordinator.setAudioInputDevice(id, label);

  Future<void> switchAsrEngine(String engine) =>
      _voiceCoordinator.switchAsrEngine(engine);

  // ---- 自诊断与意图执行 ----

  @override
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async {
    _isSelfTesting = true;
    _selfTestLogs.clear();

    final result = await DiagnosticSelfTestRunner.run(
      startWord: _settings.startWord,
      triggerMatcher: _dialogueCoordinator.triggerMatcher,
      llmService: _dialogueCoordinator.llmService,
      cameraService: cameraService,
      getSessionId: () => _sessionCoordinator.currentSessionId,
      isMessagesEmpty: () => _sessionCoordinator.messages.isEmpty,
      onResetSession: () => startNewSession(playVoice: false),
      onLog: (log) {
        _selfTestLogs.add(
          '[${DateTime.now().toIso8601String().substring(11, 19)}] $log',
        );
      },
      onStepCompleted: notifyListeners,
    );

    _isSelfTesting = false;
    notifyListeners();

    return {
      'success': result['success'],
      'logs': _selfTestLogs,
      'timestamp': result['timestamp'],
    };
  }

  Future<void> executeIntent(
    String intentName, {
    Map<String, dynamic>? parameters,
  }) async {
    switch (intentName) {
      case 'wake':
        await triggerWake(wakeWord: parameters?['word'] as String?);
        break;
      case 'reset_to_idle':
        await resetToIdle();
        break;
      case 'stop_speaking':
        await stopSpeaking();
        break;
      case 'new_session':
        await startNewSession(
          playVoice: parameters?['playVoice'] as bool? ?? false,
        );
        break;
      case 'toggle_mic':
        await toggleMicListening();
        break;
      case 'capture_and_ask':
        final q = parameters?['question'] as String? ?? '这是什么，介绍一下';
        await captureAndAskAboutScene(question: q);
        break;
      default:
        debugPrint('[AssistantEngine] 未知意图: $intentName');
    }
  }

  // ---- 设置与热更新 ----

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    final oldSettings = _settings;
    _settings = newSettings;
    await _settings.save();

    final audioChanged = oldSettings.audio != newSettings.audio;
    final visionChanged = oldSettings.vision != newSettings.vision;

    if (visionChanged) {
      _cameraService?.applyConfig(newSettings.vision);
    }

    if (audioChanged) {
      _voiceCoordinator.applyAudioConfig(
        newSettings.audio,
        newSettings: newSettings,
      );
    }

    _dialogueCoordinator.updateSettings(newSettings);

    _emit(SettingsUpdatedEvent(_settings));
    notifyListeners();
  }

  // ---- 静态处理工具与测试钩子 ----

  @visibleForTesting
  static String chooseFinalTranscript(String live, String finalText) =>
      TranscriptProcessor.chooseFinalTranscript(live, finalText);

  @visibleForTesting
  static String mergeStreamingTranscript(String current, String incoming) =>
      TranscriptProcessor.mergeStreamingTranscript(current, incoming);

  @visibleForTesting
  void setStatusForTesting(AssistantStatus status, String hint) {
    _dialogueCoordinator.setStatusForTesting(status, hint);
  }

  @visibleForTesting
  void enterContinuousModeForTesting() {
    _dialogueCoordinator.enterContinuousModeForTesting();
  }

  // ---- 销毁与生命周期 ----

  Future<void> disposeAsync() async {
    await _driverServer?.stop();
    dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _dialogueCoordinator.dispose();
    _voiceCoordinator.dispose();
    _sessionCoordinator.dispose();
    _cameraService?.dispose();
    _driverServer?.stop();
    if (!_eventController.isClosed) {
      _eventController.close();
    }
    super.dispose();
  }
}

class _DummyCameraPort implements CameraPort {
  const _DummyCameraPort();

  @override
  bool get isCameraOpen => false;

  @override
  Future<CameraCaptureResult> capturePhoto() async => CameraCaptureResult(
      imageBytes: Uint8List(0), filePath: '', isSimulated: true);

  @override
  void applyConfig(VisionConfig config) {}

  @override
  void dispose() {}

  @override
  bool get isNanoConnected => false;

  @override
  bool get isNanoConnecting => false;

  @override
  int get nanoBatteryPercent => -1;

  @override
  bool get isNanoCharging => false;

  @override
  bool get isNanoCapturing => false;

  @override
  void setNanoStateListeners({
    void Function(int batteryPercent, bool isCharging)? onBatteryUpdate,
    void Function(bool isCapturing)? onCaptureStateChanged,
  }) {}

  @override
  Future<void> toggleNanoConnection(AppSettings settings) async {}
}
