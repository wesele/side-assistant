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
      expect(settings.pipelineMode, AppConstants.defaultPipelineMode);
      expect(settings.geminiLiveModel, AppConstants.defaultGeminiLiveModel);
      expect(settings.geminiLiveVoice, AppConstants.defaultGeminiLiveVoice);
      expect(settings.geminiLiveAdvancedMode,
          AppConstants.defaultGeminiLiveAdvancedMode);
      expect(settings.geminiLiveThinkingLevel,
          AppConstants.defaultGeminiLiveThinkingLevel);
      expect(settings.geminiLiveIncludeThoughts,
          AppConstants.defaultGeminiLiveIncludeThoughts);
      expect(settings.isGeminiLiveMode, isFalse);
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

      final liveSettings = AppSettings(
        pipelineMode: AppConstants.pipelineModeGeminiLive,
        geminiApiKey: 'live-key',
        geminiLiveModel: 'gemini-3.8-live-extended-thinking',
        geminiLiveVoice: 'Kore',
        geminiLiveAdvancedMode: 'advanced',
        geminiLiveThinkingLevel: 'high',
        geminiLiveIncludeThoughts: true,
      );
      final liveRestored = AppSettings.fromMap(liveSettings.toMap());
      expect(liveRestored.pipelineMode, AppConstants.pipelineModeGeminiLive);
      expect(liveRestored.isGeminiLiveMode, isTrue);
      expect(liveRestored.geminiLiveModel, 'gemini-3.8-live-extended-thinking');
      expect(liveRestored.geminiLiveVoice, 'Kore');
      expect(liveRestored.geminiLiveAdvancedMode, 'advanced');
      expect(liveRestored.geminiLiveThinkingLevel, 'high');
      expect(liveRestored.geminiLiveIncludeThoughts, isTrue);
    });

    test('Gemini Live 高级模式与思考级别非法值安全清洗回退', () {
      final sanitized = AppSettings.fromMap({
        'geminiLiveAdvancedMode': 'non_existent_mode',
        'geminiLiveThinkingLevel': 'super_high',
        'geminiLiveIncludeThoughts': null,
      });
      expect(sanitized.geminiLiveAdvancedMode,
          equals(AppConstants.defaultGeminiLiveAdvancedMode));
      expect(sanitized.geminiLiveThinkingLevel,
          equals(AppConstants.defaultGeminiLiveThinkingLevel));
      expect(sanitized.geminiLiveIncludeThoughts,
          equals(AppConstants.defaultGeminiLiveIncludeThoughts));
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

    test('全部 31 个 Gemini Live 官方音色均有中文标签且可被 fromMap / toMap 完整保留', () {
      expect(AppConstants.geminiLiveVoices.length, equals(31));
      for (final voice in AppConstants.geminiLiveVoices) {
        expect(
          AppConstants.geminiLiveVoiceLabels.containsKey(voice),
          isTrue,
          reason: '音色 $voice 缺少中文标签',
        );
        expect(
          AppConstants.geminiLiveVoiceLabels[voice]!.trim(),
          isNotEmpty,
          reason: '音色 $voice 的中文标签不能为空',
        );

        final s = AppSettings.fromMap({'geminiLiveVoice': voice});
        expect(s.geminiLiveVoice, equals(voice), reason: '音色 $voice 应被解析');
        final exported = AppSettings.fromMap(s.toMap());
        expect(exported.geminiLiveVoice, equals(voice),
            reason: '音色 $voice 往返保留');
      }
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
