import '../models/app_settings.dart';
import '../models/assistant_status.dart';
import '../models/camera_capture_result.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../platform/foundation_bridge.dart';

export '../models/assistant_status.dart';
export '../models/camera_capture_result.dart';

/// 1. 对话与多模态交互端口 (Chat Port)
///
/// 聚焦对话流控制、LLM 交互、语音播报与即时打断。
abstract interface class ChatPort {
  AssistantStatus get status;
  String get statusHint;
  String get liveTranscript;
  String get displayTranscript;
  String get lastRecognizedSpeech;
  bool get isWakeWordMatched;
  bool get isInContinuousMode;

  Future<void> simulateUserInput(String text);
  Future<void> sendDirectUserMessage(String text);
  Future<void> sendTextMessage(String text);
  Future<void> captureAndAskAboutScene({String question = '这是什么，介绍一下'});
  Future<void> stopSpeaking();
  Future<void> speakImmediate(String text);
  Future<void> previewVoice({String? voice, String? text});
}

/// 2. 会话管理生命周期端口 (Session Port)
///
/// 聚焦会话生命周期 CRUD、历史加载与导出。
abstract interface class SessionPort {
  String get currentSessionId;
  List<ChatMessage> get messages;
  List<ChatSession> get sessions;

  Future<void> startNewSession({bool playVoice = false});
  Future<void> switchSession(String sessionId);
  Future<void> renameSession(String sessionId, String newTitle);
  Future<void> deleteSession(String sessionId);
  Future<void> clearAllHistory();
  Future<String> exportChatHistoryHtml();
}

/// 3. 声学管线与音频硬件控制端口 (Voice Control Port)
///
/// 聚焦麦克风监听、手动录音、ASR 离线/云端转写与声纹鉴权。
abstract interface class VoiceControlPort {
  bool get isMicListening;
  bool get isManualRecording;
  double get micLevel;
  double get micDbfs;
  bool get vadDetected;
  String get activeAudioInputDeviceLabel;

  int get enrolledSpeakerCount;
  bool get hasEnrolledOwner;
  String get speakerModelLabel;
  String? get lastEnrollError;

  Future<void> startManualRecording();
  Future<void> stopManualRecording();
  Future<void> toggleMicListening();
  Future<void> setAudioInputDevice(String deviceId, String label);
  Future<String?> transcribeAudioFile(String path,
      {bool isStandbyWakeCheck = false});
  Future<void> processAudioFile(String filePath);
  Float32List? getRecentAudioSnippet({double seconds = 3.0});
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5});
  Future<bool> enrollOwnerSpeaker({Float32List? samples});
  Future<void> clearOwnerSpeaker();
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity(
      {double seconds = 3.0});
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity(
      {Float32List? samples});
  Future<String> testGeminiAsrConnection({String? apiKey, String? model});
}

/// 4. 系统运行自检与全局配置端口 (System Diagnostics Port)
///
/// 聚焦硬件与网络自检、麦克风实时诊断与全局设置热更新。
abstract interface class SystemDiagnosticsPort {
  bool get isSelfTesting;
  List<String> get selfTestLogs;
  bool get isMicTesting;
  String get micTestText;
  List<Map<String, dynamic>> get micTestHistory;
  AppSettings get settings;
  bool get isQuickCapturing;

  Future<void> setMicTestMode(bool enabled, {bool clear = false});
  Future<Map<String, dynamic>> runDiagnosticSelfTest();
  Future<void> updateSettings(AppSettings newSettings);
  Future<void> setPlaybackVolume(int volume);
  Future<CameraCaptureResult> capturePhotoDirect();
}

/// 助手聚合驱动服务端端口 (Composite Driver Port)
///
/// 遵循接口隔离原则 (ISP)，聚合 ChatPort、SessionPort、VoiceControlPort 与 SystemDiagnosticsPort，
/// 并实现 [Listenable] 以支持响应式状态订阅。保持 100% 向后兼容。
abstract interface class AssistantDriverPort
    implements
        Listenable,
        ChatPort,
        SessionPort,
        VoiceControlPort,
        SystemDiagnosticsPort {}

/// 助手驱动服务宿主端口 (Driver Server Host Port)
abstract interface class DriverServerPort {
  Future<void> start();
  Future<void> stop();
}

/// 助手驱动服务工厂注册表 (Composition Root SPI 扩展点)
class DriverServerFactoryRegistry {
  static DriverServerPort Function(AssistantDriverPort driverPort)?
      defaultFactory;
}

/// 端口转发代理 Mixin (Forwarder Mixin)
///
/// 消除控制器、中间件与测试桩中的大量重复模板代理代码。
mixin AssistantDriverPortForwarder implements AssistantDriverPort {
  AssistantDriverPort get driverPortTarget;

  @override
  AssistantStatus get status => driverPortTarget.status;
  @override
  String get statusHint => driverPortTarget.statusHint;
  @override
  String get liveTranscript => driverPortTarget.liveTranscript;
  @override
  String get displayTranscript => driverPortTarget.displayTranscript;
  @override
  String get lastRecognizedSpeech => driverPortTarget.lastRecognizedSpeech;
  @override
  bool get isWakeWordMatched => driverPortTarget.isWakeWordMatched;
  @override
  bool get isInContinuousMode => driverPortTarget.isInContinuousMode;

  @override
  bool get isMicListening => driverPortTarget.isMicListening;
  @override
  bool get isManualRecording => driverPortTarget.isManualRecording;
  @override
  bool get isQuickCapturing => driverPortTarget.isQuickCapturing;
  @override
  double get micLevel => driverPortTarget.micLevel;
  @override
  double get micDbfs => driverPortTarget.micDbfs;
  @override
  bool get vadDetected => driverPortTarget.vadDetected;

  @override
  bool get isMicTesting => driverPortTarget.isMicTesting;
  @override
  String get micTestText => driverPortTarget.micTestText;
  @override
  List<Map<String, dynamic>> get micTestHistory =>
      driverPortTarget.micTestHistory;
  @override
  AppSettings get settings => driverPortTarget.settings;

  @override
  int get enrolledSpeakerCount => driverPortTarget.enrolledSpeakerCount;
  @override
  bool get hasEnrolledOwner => driverPortTarget.hasEnrolledOwner;
  @override
  String get speakerModelLabel => driverPortTarget.speakerModelLabel;
  @override
  String? get lastEnrollError => driverPortTarget.lastEnrollError;

  @override
  String get currentSessionId => driverPortTarget.currentSessionId;
  @override
  List<ChatMessage> get messages => driverPortTarget.messages;
  @override
  List<ChatSession> get sessions => driverPortTarget.sessions;

  @override
  bool get isSelfTesting => driverPortTarget.isSelfTesting;
  @override
  List<String> get selfTestLogs => driverPortTarget.selfTestLogs;
  @override
  String get activeAudioInputDeviceLabel =>
      driverPortTarget.activeAudioInputDeviceLabel;

  @override
  Future<void> simulateUserInput(String text) =>
      driverPortTarget.simulateUserInput(text);
  @override
  Future<void> sendDirectUserMessage(String text) =>
      driverPortTarget.sendDirectUserMessage(text);
  @override
  Future<void> sendTextMessage(String text) =>
      driverPortTarget.sendTextMessage(text);
  @override
  Future<void> captureAndAskAboutScene({String question = '这是什么，介绍一下'}) =>
      driverPortTarget.captureAndAskAboutScene(question: question);
  @override
  Future<void> startManualRecording() =>
      driverPortTarget.startManualRecording();
  @override
  Future<void> stopManualRecording() => driverPortTarget.stopManualRecording();
  @override
  Future<void> startNewSession({bool playVoice = false}) =>
      driverPortTarget.startNewSession(playVoice: playVoice);
  @override
  Future<void> toggleMicListening() => driverPortTarget.toggleMicListening();
  @override
  Future<void> switchSession(String sessionId) =>
      driverPortTarget.switchSession(sessionId);
  @override
  Future<void> renameSession(String sessionId, String newTitle) =>
      driverPortTarget.renameSession(sessionId, newTitle);
  @override
  Future<void> deleteSession(String sessionId) =>
      driverPortTarget.deleteSession(sessionId);
  @override
  Future<void> clearAllHistory() => driverPortTarget.clearAllHistory();
  @override
  Future<void> updateSettings(AppSettings newSettings) =>
      driverPortTarget.updateSettings(newSettings);
  @override
  Future<void> setPlaybackVolume(int volume) =>
      driverPortTarget.setPlaybackVolume(volume);
  @override
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) =>
      driverPortTarget.setMicTestMode(enabled, clear: clear);
  @override
  Future<void> stopSpeaking() => driverPortTarget.stopSpeaking();
  @override
  Future<void> speakImmediate(String text) =>
      driverPortTarget.speakImmediate(text);
  @override
  Future<void> previewVoice({String? voice, String? text}) =>
      driverPortTarget.previewVoice(voice: voice, text: text);
  @override
  Future<String> exportChatHistoryHtml() =>
      driverPortTarget.exportChatHistoryHtml();
  @override
  Future<CameraCaptureResult> capturePhotoDirect() =>
      driverPortTarget.capturePhotoDirect();
  @override
  Future<String?> transcribeAudioFile(String path,
          {bool isStandbyWakeCheck = false}) =>
      driverPortTarget.transcribeAudioFile(path,
          isStandbyWakeCheck: isStandbyWakeCheck);
  @override
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) =>
      driverPortTarget.getRecentAudioSnippet(seconds: seconds);
  @override
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) =>
      driverPortTarget.recordAndEnrollOwnerSpeaker(seconds: seconds);
  @override
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) =>
      driverPortTarget.enrollOwnerSpeaker(samples: samples);
  @override
  Future<void> clearOwnerSpeaker() => driverPortTarget.clearOwnerSpeaker();
  @override
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity(
          {double seconds = 3.0}) =>
      driverPortTarget.recordAndTestOwnerSpeakerSimilarity(seconds: seconds);
  @override
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity(
          {Float32List? samples}) =>
      driverPortTarget.testOwnerSpeakerSimilarity(samples: samples);
  @override
  Future<String> testGeminiAsrConnection({String? apiKey, String? model}) =>
      driverPortTarget.testGeminiAsrConnection(apiKey: apiKey, model: model);
  @override
  Future<void> processAudioFile(String filePath) =>
      driverPortTarget.processAudioFile(filePath);
  @override
  Future<void> setAudioInputDevice(String deviceId, String label) =>
      driverPortTarget.setAudioInputDevice(deviceId, label);
  @override
  Future<Map<String, dynamic>> runDiagnosticSelfTest() =>
      driverPortTarget.runDiagnosticSelfTest();
}
