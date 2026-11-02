import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 2: 领域化配置局部热重载隔离测试', () {
    late AssistantController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      controller = AssistantController(
        settings: AppSettings(
          openAiApiKey: 'initial-key',
          openAiModel: 'initial-model',
          playbackVolume: 50,
          asrEngine: AppConstants.asrEngineSenseVoice,
        ),
        enableDriverServer: false,
      );
      // 等待初始异步初始化完成
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    tearDown(() {
      controller.dispose();
    });

    test('修改 LLM 配置（如 API Key/模型）仅更新 LlmService，绝不重启或替换语音服务与声纹服务实例', () async {
      final initialVoiceService = controller.voiceService;
      final initialSpeakerService = controller.speakerVerificationService;
      final initialAsrService = controller.asrService;

      final newSettings = AppSettings.fromMap(controller.settings.toMap())
        ..openAiApiKey = 'updated-secret-api-key'
        ..openAiModel = 'gpt-4o'
        ..systemPrompt = '你是一个测试管家';

      await controller.updateSettings(newSettings);

      // 验证配置已更新
      expect(
          controller.settings.openAiApiKey, equals('updated-secret-api-key'));
      expect(controller.settings.openAiModel, equals('gpt-4o'));

      // 核心验证：语音监听服务、声纹服务、ASR引擎完全保持同一实例（没有被卸载和重建）
      expect(identical(controller.voiceService, initialVoiceService), isTrue,
          reason: 'VoiceListeningService 不应被销毁重建');
      expect(
          identical(
              controller.speakerVerificationService, initialSpeakerService),
          isTrue,
          reason: 'SpeakerVerificationService 不应被销毁重建');
      expect(identical(controller.asrService, initialAsrService), isTrue,
          reason: 'AsrService 不应被销毁重建');
    });

    test('修改 TTS 音量仅更新播报配置，不重启 ASR 服务', () async {
      final initialAsrService = controller.asrService;
      final initialVoiceService = controller.voiceService;

      final newSettings = AppSettings.fromMap(controller.settings.toMap())
        ..playbackVolume = 90
        ..ttsSpeed = 1.2;

      await controller.updateSettings(newSettings);

      expect(controller.settings.playbackVolume, equals(90));
      expect(controller.settings.ttsSpeed, equals(1.2));

      expect(identical(controller.asrService, initialAsrService), isTrue);
      expect(identical(controller.voiceService, initialVoiceService), isTrue);
    });

    test('修改 ASR 引擎时按需执行引擎热切换', () async {
      final initialAsrService = controller.asrService;
      expect(controller.settings.asrEngine,
          equals(AppConstants.asrEngineSenseVoice));

      final newSettings = AppSettings.fromMap(controller.settings.toMap())
        ..asrEngine = AppConstants.asrEngineStreaming;

      await controller.updateSettings(newSettings);

      expect(controller.settings.asrEngine,
          equals(AppConstants.asrEngineStreaming));
      // 引擎确实切换重建
      expect(identical(controller.asrService, initialAsrService), isFalse);
    });
  });
}
