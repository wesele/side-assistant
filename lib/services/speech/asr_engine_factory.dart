import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/ports/asr_port.dart';
import 'asr_service.dart';
import 'gemini_live_asr_service.dart';
import 'gemini_live_dialog_service.dart';

/// ASR 引擎自定义构建函数类型
typedef AsrEngineCreator = AsrService Function(AppSettings settings);

/// ASR 识别引擎组合工厂 (ASR Engine Factory)
///
/// 遵循工厂模式与 SPI（Service Provider Interface）机制：
/// 1. 根据 [AppSettings.asrEngine] 动态装配主从 ASR 引擎与仲裁策略；
/// 2. 自动化配置两阶段（Two-Pass: Streaming + SenseVoice）仲裁链条；
/// 3. 支持注册外部自定义/第三方 ASR 识别引擎（插件化扩展点）；
/// 4. 提供独立的引擎连通性诊断能力（如 Gemini Live API 探测）。
class AsrEngineFactory {
  static final Map<String, AsrEngineCreator> _customEngines = {};

  /// 注册自定义 ASR 引擎构建器 (SPI 扩展点)
  static void registerEngine(String engineType, AsrEngineCreator creator) {
    _customEngines[engineType] = creator;
  }

  /// 注销自定义 ASR 引擎构建器
  static void unregisterEngine(String engineType) {
    _customEngines.remove(engineType);
  }

  /// 清除所有自定义注册（通常在单元测试 tearDown 中调用）
  static void clearCustomEngines() {
    _customEngines.clear();
  }

  /// 注册到核心端口注册表 AsrFactoryRegistry，作为全系统默认 ASR 引擎构建源
  static void registerDefault() {
    AsrFactoryRegistry.defaultFactory = (settings) => create(settings);
    AsrFactoryRegistry.defaultGeminiTester =
        (settings, {apiKey, model}) => testGeminiConnection(
              currentSettings: settings,
              apiKey: apiKey,
              model: model,
            );
  }

  /// 是否包含指定类型的自定义引擎注册
  static bool hasCustomEngine(String engineType) =>
      _customEngines.containsKey(engineType);

  /// 根据配置构建 ASR 引擎组合包
  static AsrEngineBundle<AsrService> create(AppSettings settings) {
    AsrService primaryAsr;
    AsrService fallbackAsr;
    String primaryName;
    String fallbackName;

    final senseVoiceAsr = LocalSenseVoiceAsrService(settings: settings);

    if (_customEngines.containsKey(settings.asrEngine)) {
      primaryAsr = _customEngines[settings.asrEngine]!(settings);
      fallbackAsr = senseVoiceAsr;
      primaryName = primaryAsr.engineName;
      fallbackName = 'SenseVoice';
    } else {
      switch (settings.asrEngine) {
        case AppConstants.asrEngineStreaming:
          primaryAsr = StreamingZipformerAsrService(settings: settings);
          fallbackAsr = senseVoiceAsr;
          primaryName = 'Zipformer 流式';
          fallbackName = 'SenseVoice';
          break;
        case AppConstants.asrEngineGeminiLive:
          primaryAsr = GeminiLiveAsrService(settings: settings);
          fallbackAsr = senseVoiceAsr;
          primaryName = 'Gemini Transcribe Live';
          fallbackName = 'SenseVoice';
          break;
        case AppConstants.asrEngineSenseVoice:
        default:
          primaryAsr = senseVoiceAsr;
          fallbackAsr = StreamingZipformerAsrService(settings: settings);
          primaryName = 'SenseVoice';
          fallbackName = 'Zipformer 流式';
          break;
      }
    }

    AsrService? finalAsr;
    if (settings.enableTwoPass && primaryAsr.isStreaming) {
      finalAsr = senseVoiceAsr;
      unawaited(senseVoiceAsr.initialize());
    } else {
      finalAsr = null;
    }

    return AsrEngineBundle<AsrService>(
      primaryAsr: primaryAsr,
      fallbackAsr: fallbackAsr,
      finalAsr: finalAsr,
      primaryName: primaryName,
      fallbackName: fallbackName,
    );
  }

  /// 测试 Gemini Live API Key 与模型连通性（自适应 3.8 全双工或 3.5 Transcribe Live）
  static Future<String> testGeminiConnection({
    required AppSettings currentSettings,
    String? apiKey,
    String? model,
  }) async {
    final effectiveKey = apiKey ?? currentSettings.geminiApiKey;
    final trimmedModel = model?.trim() ?? '';
    final isFullDuplexProbe = currentSettings.isGeminiLiveMode ||
        (trimmedModel.isNotEmpty &&
            trimmedModel != AppConstants.defaultGeminiAsrModel &&
            !trimmedModel.contains('transcribe'));

    if (isFullDuplexProbe) {
      final liveModel = trimmedModel.isNotEmpty
          ? trimmedModel
          : currentSettings.geminiLiveModel;
      final probe = GeminiLiveDialogService(
        settings: currentSettings.copyWithMap({
          'geminiApiKey': effectiveKey,
          'geminiLiveModel': liveModel,
        }),
      );
      try {
        final ok = await probe.connect();
        if (ok && probe.isReady) {
          return '连接成功：Gemini Live ($liveModel)';
        }
        return '连接失败：${probe.lastError ?? '请检查 API Key、模型名与网络'}';
      } catch (e) {
        return '连接失败：$e';
      } finally {
        probe.dispose();
      }
    }

    final probe = GeminiLiveAsrService(
      settings: AppSettings(
        geminiApiKey: effectiveKey,
        geminiAsrModel: trimmedModel.isNotEmpty
            ? trimmedModel
            : currentSettings.geminiAsrModel,
      ),
    );
    try {
      await probe.initialize();
      if (probe.isReady) {
        return '连接成功：${probe.engineName}';
      }
      return '连接失败：${probe.lastError ?? '请检查 API Key、模型名与网络'}';
    } catch (e) {
      return '连接失败：$e';
    } finally {
      probe.dispose();
    }
  }
}
