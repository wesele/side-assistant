/// 空对象（Null Object）端口实现。
///
/// 用途：可选依赖缺失时让 VoicePipelineCoordinator 仍能安全运行（返回中性值、
/// 不抛异常），而非把测试替身塞进业务文件。生产路径默认装配真实实现；
/// 只有显式注入 null 时才会退化为这些实现，此时能力静默降级——排查"功能没反应"
/// 时应先确认是否落到了 Null 实现。
library;

import 'dart:typed_data';

import '../../models/app_settings.dart';
import '../../ports/asr_port.dart';
import '../../ports/speaker_verification_port.dart';
import '../../ports/target_speaker_extraction_port.dart';
import '../../ports/voice_listening_port.dart';

/// 未配置声纹服务时的空对象实现（始终旁路放行，不录入任何样本）。
class NullSpeakerVerifier implements SpeakerVerifierPort {
  const NullSpeakerVerifier();

  @override
  int get enrolledSampleCount => 0;

  @override
  bool get hasEnrolledOwner => false;

  @override
  String get modelLabel => '未配置声纹服务';

  @override
  String? get lastEnrollError => null;

  @override
  bool get isReady => false;

  @override
  double get energyThreshold => 1e-4;

  @override
  int get minAudioSamples => 4800;

  @override
  double get minSpeechSeconds => 0.3;

  @override
  Future<bool> initialize() async => true;

  @override
  SpeakerVerificationResult verifyOwner(
    Float32List audio, {
    int sampleRate = 16000,
    double? customThreshold,
    double? customMinSpeechSeconds,
    String contextHint = '唤醒',
  }) =>
      SpeakerVerificationResult.bypassed(reason: '未配置声纹服务');

  @override
  Future<bool> enrollOwner(Float32List audio) async => false;

  @override
  Future<void> clearOwnerEmbeddings() async {}

  @override
  SpeakerAnalysisResult analyzeOwner(Float32List audio) =>
      const NullSpeakerAnalysis();

  @override
  Future<String?> saveDebugWave(Float32List samples,
          {String fileName = 'speaker_test_last.wav'}) async =>
      null;

  @override
  Float32List trimAudioToSpeech(Float32List samples,
          {double minSeconds = 0.75}) =>
      samples;

  @override
  void dispose() {}
}

/// 未配置声纹服务时的空分析结果（带错误标记，调用方可据此提示用户）。
class NullSpeakerAnalysis implements SpeakerAnalysisResult {
  const NullSpeakerAnalysis();

  @override
  bool get hasError => true;

  @override
  String? get error => '未配置声纹服务';

  @override
  double get similarity => 0.0;

  @override
  double get centroidSimilarity => 0.0;

  @override
  double get maxSampleSimilarity => 0.0;

  @override
  double get meanSampleSimilarity => 0.0;

  @override
  List<double> get sampleSimilarities => const [];

  @override
  double get speechSeconds => 0.0;

  @override
  int get durationMs => 0;

  @override
  bool get insufficientSpeech => false;
}

/// 未配置目标说话人抽取服务时的空对象实现（不抽取，返回 null）。
class NullTargetSpeakerExtraction implements TargetSpeakerExtractionPort {
  const NullTargetSpeakerExtraction();

  @override
  bool get hasEnrolledOwner => false;

  @override
  dynamic extractTargetSpeaker(Float32List audio) => null;
}

/// 未配置语音监听服务时的空对象实现（不采集音频，状态保持中性）。
class NullVoiceListening implements VoiceListeningPort {
  @override
  bool isListening = false;

  @override
  bool isManualRecording = false;

  @override
  double micLevel = 0.0;

  @override
  double micDbfs = -100.0;

  @override
  bool vadDetected = false;

  @override
  String activeInputDeviceLabel = '默认麦克风';

  @override
  bool isEnrollingSpeaker = false;

  @override
  bool isMicTesting = false;

  @override
  Future<bool> startContinuousListening() async => true;

  @override
  Future<void> stopContinuousListening() async {}

  @override
  Future<void> toggleContinuousListening() async {}

  @override
  Future<bool> startManualRecording() async => true;

  @override
  Future<String?> stopManualRecording() async => null;

  @override
  Future<void> applyInputDeviceChange() async {}

  @override
  void flushBuffers({int cooldownMs = 600}) {}

  @override
  void resetStream() {}

  @override
  void performIdleHygiene() {}

  @override
  Float32List? get lastRecognizedAudio => null;

  @override
  Float32List getRecentAudio({double seconds = 2.5}) => Float32List(0);

  @override
  void clearRecentAudio() {}

  @override
  bool get isInCooldownWindow => false;

  @override
  void Function(double level, double dbfs, bool vadDetected)?
      get onAudioLevelChanged => null;

  @override
  void Function(bool isListening, String statusHint)? get onStateChanged =>
      null;

  @override
  void Function(String text, int durationMs)? get onMicTestRecognized => null;

  @override
  Future<void> setAsrService(AsrPort next) async {}

  @override
  void applyConfig(AudioConfig config) {}

  @override
  void dispose() {}
}

/// 未注册 ASR 引擎时的空对象实现（永不就绪，转写返回空串）。
class NullAsrPort implements AsrPort {
  const NullAsrPort();

  @override
  bool get isStreaming => false;

  @override
  bool get isCloudStreaming => false;

  @override
  bool get isReady => false;

  @override
  String get engineName => 'dummy';

  @override
  void Function(String text)? get onPartialText => null;

  @override
  set onPartialText(void Function(String text)? callback) {}

  @override
  double adjustVadMinSilence(double requested) => requested;

  @override
  Future<void> initialize() async {}

  @override
  Future<String> transcribeAudioFile(String filePath,
          {bool isStandbyWakeCheck = false}) async =>
      '';

  @override
  void dispose() {}
}
