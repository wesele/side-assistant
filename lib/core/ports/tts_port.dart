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

/// 语音合成工厂注册表 (Composition Root SPI 扩展点)
class TtsFactoryRegistry {
  static TtsPort Function(dynamic settings)? defaultFactory;
}

/// 空操作 TTS 兜底实现
class NoopTtsPort implements TtsPort {
  const NoopTtsPort();

  @override
  bool get isSpeaking => false;

  @override
  String get recentlySpokenText => '';

  @override
  void applyConfig(TtsConfig config) {}

  @override
  void enqueueSentence(String sentence, {bool Function()? shouldCancel}) {}

  @override
  Future<void> speakImmediate(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> waitForCompletion() async {}

  @override
  Future<void> previewVoice({
    required String voice,
    required String text,
  }) async {}

  @override
  void dispose() {}
}
