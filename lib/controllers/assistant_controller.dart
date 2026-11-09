import 'dart:async';

import '../core/platform/foundation_bridge.dart';

import '../core/engine/assistant_engine.dart';
import '../core/models/app_settings.dart';
import '../core/models/device_options.dart';
import '../core/models/custom_tool_manifest.dart';
import '../core/ports/asr_port.dart';
import '../core/ports/assistant_driver_port.dart';
import '../core/ports/chat_repository.dart';
import '../core/ports/tts_port.dart';
import '../services/llm/llm_service.dart';
import '../services/llm/tools/custom_tool_manager.dart';
import '../services/automation/app_driver_server.dart';
import '../services/speech/audio_input_device_service.dart';
import '../services/storage/chat_history_service.dart';
import '../services/storage/session_manager.dart';
import '../services/speech/foreground_service_bridge.dart';
import '../core/platform/floating_capsule_bridge.dart';
import '../services/vision/camera_service.dart';

export '../core/engine/assistant_engine.dart'
    show AudioLevelMetrics, AssistantEngineEvent, SoundEffectTriggeredEvent;
export '../core/ports/assistant_driver_port.dart';

/// 随身助理 Flutter 应用层驱动控制器 (Application Layer Presentation Controller)
///
/// 遵循关注点分离与接口隔离原则 (ISP)：
/// 组合纯 Dart 核心领域引擎 [AssistantEngine]，负责前台服务桥接、悬浮胶囊交互，
/// 并驱动 Flutter Widget 树响应式更新。
///
/// 通过 [AssistantDriverPortForwarder] 实现微端口代理转发，消除约 200 行无意义的样板转发代码。
class AssistantController extends ChangeNotifier
    with AssistantDriverPortForwarder
    implements AssistantDriverPort {
  final AssistantEngine _engine;
  AssistantEngine get engine => _engine;

  @override
  AssistantDriverPort get driverPortTarget => _engine;

  StreamSubscription<AssistantEngineEvent>? _engineEventSub;
  final ValueNotifier<AudioLevelMetrics> audioMetricsNotifier =
      ValueNotifier(const AudioLevelMetrics());

  AppDriverServer? _driverServer;
  String _lastFloatingStatus = '';
  bool? _lastFloatingMic;

  AssistantController({
    required AppSettings settings,
    bool enableDriverServer = true,
    ChatHistoryService? chatHistoryService,
    dynamic llmService,
    AssistantEngine? engine,
  }) : _engine = engine ??
            AssistantEngine(
              settings: settings,
              chatHistoryService: chatHistoryService,
              injectedLlmService: llmService,
            ) {
    _initEngineListeners();
    _setupPlatformBridges();

    if (enableDriverServer) {
      _driverServer = AppDriverServer(controller: this);
      unawaited(_driverServer!.start());
    }
  }

  void _initEngineListeners() {
    _engineEventSub = _engine.events.listen(_handleEngineEvent);
  }

  void _handleEngineEvent(AssistantEngineEvent event) {
    if (event is MetricsUpdatedEvent) {
      // 高频音频指标仅通知专用 ValueNotifier，避免触发全树 notifyListeners 损耗帧率
      audioMetricsNotifier.value = event.metrics;
      return;
    }

    if (event is StatusChangedEvent || event is MicListeningChangedEvent) {
      _syncForegroundNotification();
      unawaited(_syncFloatingCapsule());
    }

    notifyListeners();
  }

  void _setupPlatformBridges() {
    FloatingCapsuleService.setActionHandler((action) async {
      switch (action) {
        case 'captureAndAsk':
          await _engine.captureAndAskAboutScene();
          break;
        case 'toggleMic':
          await toggleMicListening();
          break;
      }
    });

    unawaited(
      FloatingCapsuleService.setEnabled(
        settings.enableFloatingCapsule,
        micListening: _engine.isMicListening,
        status: floatingCapsuleStatusLabel,
      ),
    );
    unawaited(_syncFloatingCapsule(force: true));
  }

  String get floatingCapsuleStatusLabel => _engine.statusShortLabel;

  void _syncForegroundNotification() {
    if (!_engine.isMicListening) return;
    ForegroundServiceBridge.update(
      title: '随身助理 - $floatingCapsuleStatusLabel',
      content: _engine.statusHint,
    );
  }

  Future<void> _syncFloatingCapsule({bool force = false}) async {
    if (!FloatingCapsuleService.isSupported) return;

    final status = floatingCapsuleStatusLabel;
    final mic = _engine.isMicListening;
    if (!force && status == _lastFloatingStatus && mic == _lastFloatingMic) {
      return;
    }
    _lastFloatingStatus = status;
    _lastFloatingMic = mic;

    await FloatingCapsuleService.update(
      status: status,
      micListening: mic,
      enabled: settings.enableFloatingCapsule,
    );
  }

  // ---- 局部复写与属性访问器 ----

  @override
  AppSettings get settings => _engine.settings;
  set settings(AppSettings value) => _engine.settings = value;

  bool get isEnrollingSpeaker => _engine.isEnrollingSpeaker;

  // ---- 子服务与扩展属性委托 ----

  AsrPort get asrService => _engine.asrService;
  TtsPort get ttsService => _engine.ttsService;
  VoiceListeningPort get voiceService => _engine.voiceService;
  SpeakerVerifierPort get speakerVerificationService =>
      _engine.speakerVerificationService;
  TargetSpeakerExtractionPort get targetSpeakerExtractionService =>
      _engine.targetSpeakerExtractionService;
  SessionManager get sessionManager => _engine.sessionManager;
  ChatRepository get chatHistoryService => _engine.chatHistoryService;
  CameraPort get cameraService => _engine.cameraService;
  int get acknowledgeBeepCount => _engine.acknowledgeBeepCount;
  bool get isCameraOpen => _engine.isCameraOpen;
  bool get isNanoConnected => _engine.isNanoConnected;
  bool get isNanoConnecting => _engine.isNanoConnecting;
  bool get isNanoCameraMode => _engine.isNanoCameraMode;
  int get nanoBatteryPercent => _engine.nanoBatteryPercent;
  bool get isNanoCharging => _engine.isNanoCharging;
  bool get isNanoCapturing => _engine.isNanoCapturing;
  bool get isWakeWordRequired => _engine.isWakeWordRequired;
  AppDriverServer? get driverServer => _driverServer;

  @override
  Future<void> toggleMicListening() async {
    await _engine.toggleMicListening();
    await _syncFloatingCapsule(force: true);
  }

  // ---- 扩展业务与测试辅助委托 ----

  Future<List<String>> getWlanInterfaces() => CameraService.getWlanInterfaces();
  Future<bool> hasCameraPermission() => CameraService.hasCameraPermission();
  Future<bool> requestCameraPermission() =>
      CameraService.requestCameraPermission();
  Future<void> openCameraAppSettings() => CameraService.openAppSettings();
  Future<List<CameraResolution>> getAvailableCameraResolutions({
    String lensDirection = 'back',
  }) =>
      CameraService.getAvailableResolutions(lensDirection: lensDirection);
  Future<NanoLinkTestResult> testNanoLink({
    required AppSettings settings,
    String? bleAddressOverride,
    required String wlanInterface,
    void Function(String status)? onProgress,
    void Function(String bleAddress)? onBleAddressFound,
  }) =>
      CameraService.testNanoLink(
        settings: settings,
        bleAddressOverride: bleAddressOverride,
        wlanInterface: wlanInterface,
        onProgress: onProgress,
        onBleAddressFound: onBleAddressFound,
      );
  Future<List<String>> fetchAvailableModels({
    required String baseUrl,
    required String apiKey,
  }) =>
      LlmService.fetchAvailableModels(baseUrl: baseUrl, apiKey: apiKey);

  List<CustomToolManifest> listCustomTools() =>
      CustomToolManager.instance.listToolsSync();

  bool deleteCustomTool(String name) =>
      CustomToolManager.instance.deleteTool(name);

  Future<void> toggleNanoConnection() => _engine.toggleNanoConnection();
  Future<void> processRecognizedText(String recognizedText) =>
      _engine.processRecognizedText(recognizedText);
  Future<void> processPartialTranscript(String partialText) =>
      _engine.processPartialTranscript(partialText);
  Future<void> processFinalTranscript(String finalText) =>
      _engine.processFinalTranscript(finalText);
  Future<void> playAcknowledgeBeep() => _engine.playAcknowledgeBeep();
  Future<void> loadChatHistory() => _engine.loadChatHistory();
  Future<String> exportAllHistoryToHtml() => _engine.exportAllHistoryToHtml();
  Future<List<AudioInputDeviceOption>> listAudioInputDevices() =>
      _engine.listAudioInputDevices();

  @visibleForTesting
  static String chooseFinalTranscript(String live, String finalText) =>
      AssistantEngine.chooseFinalTranscript(live, finalText);

  @visibleForTesting
  static String mergeStreamingTranscript(String current, String incoming) =>
      AssistantEngine.mergeStreamingTranscript(current, incoming);

  @visibleForTesting
  void setStatusForTesting(AssistantStatus status, String hint) =>
      _engine.setStatusForTesting(status, hint);

  @visibleForTesting
  void enterContinuousModeForTesting() =>
      _engine.enterContinuousModeForTesting();

  Future<void> disposeAsync() async {
    await _driverServer?.stop();
    dispose();
  }

  @override
  void dispose() {
    _engineEventSub?.cancel();
    _driverServer?.stop();
    FloatingCapsuleService.setActionHandler(null);
    audioMetricsNotifier.dispose();
    _engine.dispose();
    super.dispose();
  }
}
