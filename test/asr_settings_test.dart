import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  group('ASR 设置序列化', () {
    test('新字段有安全默认值', () {
      final settings = AppSettings();
      expect(settings.asrEngine, AppConstants.defaultAsrEngine);
      expect(settings.vadThreshold, AppConstants.defaultVadThreshold);
      expect(settings.vadMinSilenceSeconds, 0.50);
      expect(settings.vadMinSpeechSeconds, 0.25);
      expect(settings.vadMaxSpeechSeconds, 30.0);
      expect(settings.preRollMs, 300);
      expect(settings.postRollMs, 200);
      expect(settings.enableTwoPass, isTrue);
      expect(settings.autoSubmitOnTimeout, isTrue);
      expect(settings.geminiApiKey, AppConstants.defaultGeminiApiKey);
      expect(settings.geminiAsrModel, AppConstants.defaultGeminiAsrModel);
    });

    test('toMap / fromMap 往返保留新字段', () {
      final settings = AppSettings(
        asrEngine: AppConstants.asrEngineStreaming,
        vadThreshold: 0.35,
        vadMinSilenceSeconds: 0.65,
        vadMinSpeechSeconds: 0.30,
        vadMaxSpeechSeconds: 45,
        preRollMs: 350,
        postRollMs: 250,
        enableTwoPass: false,
        autoSubmitOnTimeout: false,
      );

      final restored = AppSettings.fromMap(settings.toMap());
      expect(restored.asrEngine, AppConstants.asrEngineStreaming);
      expect(restored.vadThreshold, 0.35);
      expect(restored.vadMinSilenceSeconds, 0.65);
      expect(restored.vadMinSpeechSeconds, 0.30);
      expect(restored.vadMaxSpeechSeconds, 45);
      expect(restored.preRollMs, 350);
      expect(restored.postRollMs, 250);
      expect(restored.enableTwoPass, isFalse);
      expect(restored.autoSubmitOnTimeout, isFalse);
    });

    test('Gemini 云端引擎与 Key/模型可序列化', () {
      final settings = AppSettings(
        asrEngine: AppConstants.asrEngineGeminiLive,
        geminiApiKey: 'test-key',
        geminiAsrModel: 'gemini-3.5-transcribe-live',
      );

      final restored = AppSettings.fromMap(settings.toMap());
      expect(restored.asrEngine, AppConstants.asrEngineGeminiLive);
      expect(restored.geminiApiKey, 'test-key');
      expect(restored.geminiAsrModel, 'gemini-3.5-transcribe-live');
    });

    test('旧版配置（缺少新字段）可平滑升级', () {
      final restored = AppSettings.fromMap({
        'startWord': '晓漫',
        'endWord': '回答',
        'resetWord': '新起一个',
        'asrEngine': 'sensevoice',
      });
      expect(restored.asrEngine, 'sensevoice');
      expect(restored.vadMinSilenceSeconds, 0.50);
      expect(restored.enableTwoPass, isTrue);
    });

    test('已移除的旧引擎值会回退到默认引擎', () {
      for (final removed in ['firered', 'streaming_zh', 'lan', 'unknown']) {
        final restored = AppSettings.fromMap({'asrEngine': removed});
        expect(
          restored.asrEngine,
          AppConstants.defaultAsrEngine,
          reason: '$removed 应回退默认引擎',
        );
      }
    });
  });
}
