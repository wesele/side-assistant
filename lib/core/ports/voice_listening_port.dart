import 'dart:typed_data';

import '../models/app_settings.dart';
import 'asr_port.dart';
import 'speaker_verification_port.dart';

/// 实时语音监听与声学采集流水线端口 (Voice Listening Port)
abstract interface class VoiceListeningPort {
  bool get isListening;
  bool get isManualRecording;
  double get micLevel;
  double get micDbfs;
  bool get vadDetected;
  String get activeInputDeviceLabel;
  bool get isEnrollingSpeaker;
  set isEnrollingSpeaker(bool value);
  bool get isMicTesting;
  set isMicTesting(bool value);

  Future<bool> startContinuousListening();
  Future<void> stopContinuousListening();
  Future<void> toggleContinuousListening();
  Future<bool> startManualRecording();
  Future<String?> stopManualRecording();
  Future<void> applyInputDeviceChange();

  void flushBuffers({int cooldownMs = 600});
  void resetStream();
  void performIdleHygiene();

  Float32List? get lastRecognizedAudio;
  Float32List getRecentAudio({double seconds = 2.5});
  void clearRecentAudio();

  void Function(double level, double dbfs, bool vadDetected)?
      get onAudioLevelChanged => null;
  void Function(bool isListening, String statusHint)? get onStateChanged =>
      null;
  void Function(String text, int durationMs)? get onMicTestRecognized => null;
  bool get isInCooldownWindow => false;

  Future<void> setAsrService(AsrPort next);
  void applyConfig(AudioConfig config);
  void dispose();
}

typedef VoiceListeningFactory = VoiceListeningPort Function({
  required AppSettings settings,
  required AsrPort asrService,
  AsrPort? finalAsrService,
  SpeakerVerifierPort? speakerVerificationService,
  void Function(String text)? onFinalTranscript,
  void Function(String text)? onTextRecognized,
  void Function(String text)? onManualRecordingRecognized,
  void Function(Float32List samples)? onRawAudioSamples,
  void Function(double level, double dbfs, bool vadDetected)?
      onAudioLevelChanged,
  void Function(String text, int durationMs)? onMicTestRecognized,
  void Function(bool isListening, String statusHint)? onStateChanged,
  bool Function()? isStandbyMode,
  bool Function()? isPlayingMode,
});

/// 语音采集流水线 SPI 工厂注册表
class VoiceListeningFactoryRegistry {
  static VoiceListeningFactory? defaultFactory;
}
