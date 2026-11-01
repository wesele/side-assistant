import '../models/domain_configs.dart';

/// 语音合成服务端口 (TTS Port)
///
/// 定义文本流式播报、即时打断与语音试听契约。
abstract interface class TtsPort {
  bool get isSpeaking;
  String get recentlySpokenText;

  void applyConfig(TtsConfig config);

  void enqueueSentence(String sentence, {bool Function()? shouldCancel});

  Future<void> speakImmediate(String text);

  Future<void> stop();

  Future<void> waitForCompletion();

  Future<void> previewVoice({
    required String voice,
    required String text,
  });

  void dispose();
}
