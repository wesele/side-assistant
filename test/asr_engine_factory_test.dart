import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/ports/asr_port.dart';
import 'package:side_assistant/services/speech/asr_engine_factory.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';

class _FakeCustomAsrService extends AsrService {
  @override
  final AppSettings settings;
  _FakeCustomAsrService(this.settings);

  @override
  String get engineName => 'CustomPluginAsr';

  @override
  bool get isReady => true;

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async =>
      '';
}

void main() {
  setUp(() {
    AsrEngineFactory.clearCustomEngines();
    AsrEngineFactory.registerDefault();
  });

  tearDown(() {
    AsrEngineFactory.clearCustomEngines();
  });

  group('AsrEngineFactory 工厂与 SPI 装配测试', () {
    test('1. 默认 SenseVoice 引擎包装配', () {
      final settings = AppSettings(
        asrEngine: AppConstants.asrEngineSenseVoice,
        enableTwoPass: false,
      );

      final bundle = AsrEngineFactory.create(settings);

      expect(bundle.primaryName, equals('SenseVoice'));
      expect(bundle.primaryAsr, isA<LocalSenseVoiceAsrService>());
      expect(bundle.fallbackName, contains('Zipformer'));
      expect(bundle.fallbackAsr, isA<StreamingZipformerAsrService>());
      expect(bundle.finalAsr, isNull);
    });

    test('2. Streaming Zipformer 引擎装配与 Two-Pass 两阶段仲裁', () {
      // 开启两阶段
      final settingsTwoPass = AppSettings(
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: true,
      );

      final bundleTwoPass = AsrEngineFactory.create(settingsTwoPass);
      expect(bundleTwoPass.primaryName, contains('Zipformer'));
      expect(bundleTwoPass.primaryAsr, isA<StreamingZipformerAsrService>());
      expect(bundleTwoPass.primaryAsr.isStreaming, isTrue);
      expect(bundleTwoPass.finalAsr, isNotNull);
      expect(bundleTwoPass.finalAsr, isA<LocalSenseVoiceAsrService>());

      // 关闭两阶段
      final settingsNoTwoPass = AppSettings(
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
      );
      final bundleNoTwoPass = AsrEngineFactory.create(settingsNoTwoPass);
      expect(bundleNoTwoPass.finalAsr, isNull);
    });

    test('3. Gemini Live 云端识别引擎装配', () {
      final settings = AppSettings(
        asrEngine: AppConstants.asrEngineGeminiLive,
      );

      final bundle = AsrEngineFactory.create(settings);
      expect(bundle.primaryName, equals('Gemini Transcribe Live'));
      expect(bundle.primaryAsr, isA<GeminiLiveAsrService>());
      expect(bundle.fallbackAsr, isA<LocalSenseVoiceAsrService>());
    });

    test('4. SPI 自定义第三方 ASR 引擎注册与解绑生命周期', () {
      const customType = 'third_party_whisper';
      expect(AsrEngineFactory.hasCustomEngine(customType), isFalse);

      AsrEngineFactory.registerEngine(
        customType,
        (settings) => _FakeCustomAsrService(settings),
      );

      expect(AsrEngineFactory.hasCustomEngine(customType), isTrue);

      final settings = AppSettings(asrEngine: customType);
      final bundle = AsrEngineFactory.create(settings);

      expect(bundle.primaryName, equals('CustomPluginAsr'));
      expect(bundle.primaryAsr, isA<_FakeCustomAsrService>());
      expect(bundle.fallbackAsr, isA<LocalSenseVoiceAsrService>());

      // 注销自定义引擎
      AsrEngineFactory.unregisterEngine(customType);
      expect(AsrEngineFactory.hasCustomEngine(customType), isFalse);

      // 注销后回退为默认引擎
      final fallbackBundle = AsrEngineFactory.create(settings);
      expect(fallbackBundle.primaryAsr, isA<LocalSenseVoiceAsrService>());
    });

    test('5. AsrFactoryRegistry 全局核心委托桥接验证', () {
      expect(AsrFactoryRegistry.defaultFactory, isNotNull);
      expect(AsrFactoryRegistry.defaultGeminiTester, isNotNull);

      final settings = AppSettings(asrEngine: AppConstants.asrEngineSenseVoice);
      final bundle = AsrFactoryRegistry.defaultFactory!(settings);

      expect(bundle.primaryName, equals('SenseVoice'));
      expect(bundle.primaryAsr, isA<AsrPort>());
    });
  });
}
