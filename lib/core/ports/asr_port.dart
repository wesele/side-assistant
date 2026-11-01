import '../models/app_settings.dart';

/// 语音识别服务端口 (ASR Port)
///
/// 定义离线/流式语音识别的生命周期与音频转写契约。
abstract interface class AsrPort {
  bool get isStreaming;
  bool get isCloudStreaming;
  bool get isReady;
  String get engineName;

  void Function(String text)? get onPartialText;
  set onPartialText(void Function(String text)? callback);

  double adjustVadMinSilence(double requested);

  Future<void> initialize();

  Future<String> transcribeAudioFile(
    String filePath, {
    bool isStandbyWakeCheck = false,
  });

  void dispose();
}

/// ASR 识别引擎组合包（包含主识别引擎、降级备用引擎及可选两阶段终审引擎）
class AsrEngineBundle<T extends AsrPort> {
  final T primaryAsr;
  final T fallbackAsr;
  final T? finalAsr;
  final String primaryName;
  final String fallbackName;

  const AsrEngineBundle({
    required this.primaryAsr,
    required this.fallbackAsr,
    this.finalAsr,
    required this.primaryName,
    required this.fallbackName,
  });
}

/// ASR 引擎工厂注册表 (Core Service Provider Registry)
///
/// 遵循六边形架构依赖倒置原则：允许服务实现层在 Composition Root 中注册
/// ASR 构建与探测策略，使核心协调器与具体实现解耦。
class AsrFactoryRegistry {
  static AsrEngineBundle<AsrPort> Function(AppSettings settings)? defaultFactory;
  static Future<String> Function(AppSettings settings, {String? apiKey, String? model})?
      defaultGeminiTester;
}

