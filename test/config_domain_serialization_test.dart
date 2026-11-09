import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  group('配置领域化与平坦序列化兼容性测试 (AGENTS.md 规范)', () {
    test('默认配置序列化与反序列化 100% 平坦字段一致性', () {
      final defaultSettings = AppSettings();
      final map = defaultSettings.toMap();

      // 验证核心平坦字段全部存在
      expect(map.containsKey('startWord'), isTrue);
      expect(map.containsKey('endWord'), isTrue);
      expect(map.containsKey('openAiBaseUrl'), isTrue);
      expect(map.containsKey('openAiApiKey'), isTrue);
      expect(map.containsKey('openAiModel'), isTrue);
      expect(map.containsKey('enableOpenCode'), isTrue);
      expect(map.containsKey('codeAgentProvider'), isTrue);
      expect(map.containsKey('openCodeCommand'), isTrue);
      expect(map.containsKey('hermesCommand'), isTrue);
      expect(map.containsKey('openCodeTimeoutSeconds'), isTrue);
      expect(map.containsKey('ttsEngine'), isTrue);
      expect(map.containsKey('playbackVolume'), isTrue);
      expect(map.containsKey('captureSource'), isTrue);
      expect(map.containsKey('nanoBleAddress'), isTrue);
      expect(map.containsKey('webAccessPassword'), isTrue);
      expect(map.containsKey('autoStartMicOnLaunch'), isTrue);

      // JSON 序列化反序列化双向无损
      final jsonStr = jsonEncode(map);
      final restoredMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final restored = AppSettings.fromMap(restoredMap);

      expect(restored.startWord, equals(defaultSettings.startWord));
      expect(restored.openAiModel, equals(defaultSettings.openAiModel));
      expect(restored.enableOpenCode, equals(defaultSettings.enableOpenCode));
      expect(restored.codeAgentProvider,
          equals(defaultSettings.codeAgentProvider));
      expect(restored.openCodeCommand, equals(defaultSettings.openCodeCommand));
      expect(restored.hermesCommand, equals(defaultSettings.hermesCommand));
      expect(restored.openCodeTimeoutSeconds,
          equals(defaultSettings.openCodeTimeoutSeconds));
      expect(restored.playbackVolume, equals(defaultSettings.playbackVolume));
      expect(restored.captureSource, equals(defaultSettings.captureSource));
      expect(restored.audio.asrEngine, equals(defaultSettings.audio.asrEngine));
    });

    test('全字段自定义配置平坦双向兼容', () {
      final customMap = <String, dynamic>{
        'startWord': '自定义唤醒词',
        'endWord': '结束回答',
        'resetWord': '重新来过',
        'exitContinuousWord': '跪安吧',
        'startWordMode': 'enabled',
        'enableStartWordDetection': true,
        'continuousModeTimeoutMinutes': 15,
        'similarityThreshold': 0.85,
        'silenceTimeoutSeconds': 8,
        'asrEngine': AppConstants.asrEngineSenseVoice,
        'vadThreshold': 0.45,
        'vadMinSilenceSeconds': 0.6,
        'vadMinSpeechSeconds': 0.3,
        'vadMaxSpeechSeconds': 25.0,
        'preRollMs': 350,
        'postRollMs': 250,
        'enableTwoPass': false,
        'autoSubmitOnTimeout': false,
        'openAiBaseUrl': 'https://api.mycustomllm.com/v1',
        'openAiApiKey': 'sk-custom-secret-key-123456789',
        'openAiModel': 'gpt-4o-mini',
        'disableThinking': true,
        'enableWebSearch': false,
        'enableOpenCode': false,
        'codeAgentProvider': 'hermes',
        'openCodeCommand': '/usr/local/bin/opencode',
        'hermesCommand': '/opt/hermes/bin/hermes',
        'openCodeTimeoutSeconds': 180,
        'enableLightRag': true,
        'lightRagBaseUrl': 'http://10.0.0.99:9621',
        'systemPrompt': '你是一个自定义助手。',
        'geminiApiKey': 'gemini-key-xyz',
        'geminiAsrModel': 'gemini-model-test',
        'audioInputDeviceId': 'alsa:hw:1,0',
        'audioInputDeviceLabel': 'USB Mic',
        'audioOutputDeviceId': 'alsa:hw:1,0',
        'audioOutputDeviceLabel': 'USB Speaker',
        'linuxCameraDevice': '/dev/video2',
        'autoStartMicOnLaunch': false,
        'webAccessPassword': 'SuperSecretPassword',
        'enableBargeIn': false,
        'enableTtsPlayback': false,
        'ttsSpeed': 1.25,
        'playbackVolume': 95,
        'enablePromptTone': false,
        'ttsEngine': 'system',
        'edgeVoice': 'zh-CN-YunxiNeural',
        'locationAddress': '北京朝阳区',
        'captureSource': 'nano',
        'nanoWlanInterface': 'wlan1',
        'nanoSsid': 'Nano_SSID_5G',
        'nanoPassword': 'NanoPassword123',
        'nanoBleAddress': 'AA:BB:CC:DD:EE:FF',
        'enableVisionIntent': false,
        'visionSimilarityThreshold': 0.72,
        'cameraKeepAliveMinutes': 5,
        'cameraLensDirection': 'front',
        'cameraResolutionWidth': 1920,
        'cameraResolutionHeight': 1080,
        'cameraSendShortEdge': 1080,
        'customVisionPrototypes': ['proto1', 'proto2'],
        'cachedAvailableModels': ['model-a', 'model-b'],
        'enableFloatingCapsule': true,
        'enableSpeakerVerification': true,
        'speakerSimilarityThreshold': 0.77,
        'speakerVerifyWakeOnly': false,
        'speakerModelPath': '/path/to/custom_speaker.onnx',
        'ownerSpeakerEmbeddings': [
          [0.1, 0.2, 0.3],
          [0.4, 0.5, 0.6],
        ],
        'enableTargetSpeakerExtraction': true,
        'tseSimilarityThreshold': 0.73,
        'tseAttenuationDb': 18.0,
        'geminiLiveAdvancedMode': 'advanced',
        'geminiLiveThinkingLevel': 'high',
        'geminiLiveIncludeThoughts': true,
      };

      final settings = AppSettings.fromMap(customMap);

      // 验证各个领域对象正确反序列化
      expect(settings.audio.startWord, equals('自定义唤醒词'));
      expect(settings.audio.geminiLiveAdvancedMode, equals('advanced'));
      expect(settings.audio.geminiLiveThinkingLevel, equals('high'));
      expect(settings.audio.geminiLiveIncludeThoughts, isTrue);
      expect(settings.audio.ownerSpeakerEmbeddings.length, equals(2));
      expect(
          settings.llm.openAiApiKey, equals('sk-custom-secret-key-123456789'));
      expect(settings.llm.disableThinking, isTrue);
      expect(settings.llm.enableOpenCode, isFalse);
      expect(settings.llm.codeAgentProvider, equals('hermes'));
      expect(settings.llm.openCodeCommand, equals('/usr/local/bin/opencode'));
      expect(settings.llm.hermesCommand, equals('/opt/hermes/bin/hermes'));
      expect(settings.llm.openCodeTimeoutSeconds, equals(180));
      expect(settings.tts.playbackVolume, equals(95));
      expect(settings.tts.ttsSpeed, equals(1.25));
      expect(settings.vision.nanoBleAddress, equals('AA:BB:CC:DD:EE:FF'));
      expect(settings.server.webAccessPassword, equals('SuperSecretPassword'));

      // 验证平坦 getter 转发
      expect(settings.startWord, equals('自定义唤醒词'));
      expect(settings.openAiApiKey, equals('sk-custom-secret-key-123456789'));
      expect(settings.enableOpenCode, isFalse);
      expect(settings.codeAgentProvider, equals('hermes'));
      expect(settings.openCodeCommand, equals('/usr/local/bin/opencode'));
      expect(settings.hermesCommand, equals('/opt/hermes/bin/hermes'));
      expect(settings.openCodeTimeoutSeconds, equals(180));
      expect(settings.playbackVolume, equals(95));
      expect(settings.webAccessPassword, equals('SuperSecretPassword'));
      expect(settings.geminiLiveAdvancedMode, equals('advanced'));
      expect(settings.geminiLiveThinkingLevel, equals('high'));
      expect(settings.geminiLiveIncludeThoughts, isTrue);

      // 序列化后平坦输出与输入完全等价
      final outputMap = settings.toMap();
      for (final key in customMap.keys) {
        expect(outputMap.containsKey(key), isTrue,
            reason: 'Missing key $key in outputMap');
        expect(outputMap[key], equals(customMap[key]),
            reason: 'Value mismatch for key $key');
      }
    });

    test('局部配置变更时领域对象相等性比较精确隔离', () {
      final s1 = AppSettings();
      final s2 = AppSettings(
        audio: s1.audio,
        llm: s1.llm.copyWith(openAiApiKey: 'new-key'),
        tts: s1.tts,
        vision: s1.vision,
        server: s1.server,
      );

      // 仅 llm 领域变更，其它领域完全相等
      expect(s1.audio == s2.audio, isTrue);
      expect(s1.tts == s2.tts, isTrue);
      expect(s1.vision == s2.vision, isTrue);
      expect(s1.server == s2.server, isTrue);
      expect(s1.llm == s2.llm, isFalse);
    });

    test('DomainConfig 深度集合判等与哈希正确性验证', () {
      const a1 = AudioConfig(
        ownerSpeakerEmbeddings: [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
      );
      const a2 = AudioConfig(
        ownerSpeakerEmbeddings: [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
      );
      const a3 = AudioConfig(
        ownerSpeakerEmbeddings: [
          [1.0, 2.0],
          [3.0, 4.1],
        ],
      );

      expect(a1 == a2, isTrue);
      expect(a1.hashCode, equals(a2.hashCode));
      expect(a1 == a3, isFalse);

      final l1 = LlmConfig(cachedAvailableModels: ['m1', 'm2']);
      final l2 = LlmConfig(cachedAvailableModels: ['m1', 'm2']);
      final l3 = LlmConfig(cachedAvailableModels: ['m1', 'm3']);

      expect(l1 == l2, isTrue);
      expect(l1.hashCode, equals(l2.hashCode));
      expect(l1 == l3, isFalse);
    });

    test('DomainConfigs 独立序列化与反序列化往返契约 (LlmConfig Hermes)', () {
      final config = LlmConfig(
        codeAgentProvider: 'hermes',
        hermesCommand: '/opt/hermes/bin/hermes',
      );
      final map = config.toMap();
      expect(map['codeAgentProvider'], equals('hermes'));
      expect(map['hermesCommand'], equals('/opt/hermes/bin/hermes'));

      final restored = LlmConfig.fromMap(map);
      expect(restored.codeAgentProvider, equals('hermes'));
      expect(restored.hermesCommand, equals('/opt/hermes/bin/hermes'));
    });

    test('AppSettings 门面委托与增量更新契约 (copyWith / copyWithMap / applyMap)', () {
      final s = AppSettings(
        startWord: '原有唤醒词',
        openAiModel: '原有模型',
        playbackVolume: 50,
      );

      // copyWith 与 copyWithMap 验证
      final copiedLlm = s.llm.copyWith(
        codeAgentProvider: 'hermes',
        hermesCommand: '/opt/hermes/bin/hermes',
      );
      expect(copiedLlm.codeAgentProvider, equals('hermes'));
      expect(copiedLlm.hermesCommand, equals('/opt/hermes/bin/hermes'));

      final sWithCopiedLlm = AppSettings(llm: copiedLlm);
      expect(sWithCopiedLlm.codeAgentProvider, equals('hermes'));
      expect(sWithCopiedLlm.hermesCommand, equals('/opt/hermes/bin/hermes'));

      final delta = {
        'startWord': '新唤醒词',
        'openAiModel': '新模型',
        'playbackVolume': 85,
        'codeAgentProvider': 'hermes',
        'hermesCommand': '/opt/hermes/bin/hermes',
      };

      // 1. 不可变更新 copyWithMap
      final updated = s.copyWithMap(delta);
      expect(updated.startWord, equals('新唤醒词'));
      expect(updated.openAiModel, equals('新模型'));
      expect(updated.playbackVolume, equals(85));
      expect(updated.codeAgentProvider, equals('hermes'));
      expect(updated.hermesCommand, equals('/opt/hermes/bin/hermes'));
      expect(s.startWord, equals('原有唤醒词')); // 原对象不变

      // 2. 就地更新 applyMap
      s.applyMap(delta);
      expect(s.startWord, equals('新唤醒词'));
      expect(s.openAiModel, equals('新模型'));
      expect(s.playbackVolume, equals(85));
      expect(s.codeAgentProvider, equals('hermes'));
      expect(s.hermesCommand, equals('/opt/hermes/bin/hermes'));
    });

    test('LlmConfig OpenCode 配置解析与超限 clamp 校验 (缺省值与非法边界值自愈降级)', () {
      // 1. 默认值与空命令回退
      final fallbackConfig = LlmConfig.fromMap({
        'openCodeCommand': '   ',
        'openCodeTimeoutSeconds': null,
      });
      expect(fallbackConfig.enableOpenCode, isTrue);
      expect(fallbackConfig.openCodeCommand,
          equals(AppConstants.defaultOpenCodeCommand));
      expect(fallbackConfig.openCodeTimeoutSeconds,
          equals(AppConstants.defaultOpenCodeTimeoutSeconds));

      // 缺省值与非法边界值自愈降级 (Hermes / OpenCode)
      final hermesNormalized = LlmConfig.fromMap({
        'codeAgentProvider': '  HERMES ',
      });
      expect(hermesNormalized.codeAgentProvider, equals('hermes'));

      final invalidAgentFallback = LlmConfig.fromMap({
        'codeAgentProvider': 'invalid_agent',
      });
      expect(invalidAgentFallback.codeAgentProvider, equals('opencode'));

      final emptyAgentFallback = LlmConfig.fromMap({
        'codeAgentProvider': '',
      });
      expect(emptyAgentFallback.codeAgentProvider, equals('opencode'));

      final hermesCmdFallback = LlmConfig.fromMap({
        'hermesCommand': '   ',
      });
      expect(hermesCmdFallback.hermesCommand, equals('hermes'));

      // 2. 超限下界 clamp(10, 600)
      final minClamped = LlmConfig.fromMap({
        'openCodeTimeoutSeconds': 2,
      });
      expect(minClamped.openCodeTimeoutSeconds, equals(10));

      // 3. 超限上界 clamp(10, 600)
      final maxClamped = LlmConfig.fromMap({
        'openCodeTimeoutSeconds': 9999,
      });
      expect(maxClamped.openCodeTimeoutSeconds, equals(600));

      // 4. AppSettings 门面代理与 copyWithMap / applyMap 增量更新
      final s = AppSettings();
      expect(s.enableOpenCode, isTrue);
      s.applyMap({
        'enableOpenCode': false,
        'openCodeCommand': 'opencode-custom',
        'openCodeTimeoutSeconds': 45,
      });
      expect(s.enableOpenCode, isFalse);
      expect(s.openCodeCommand, equals('opencode-custom'));
      expect(s.openCodeTimeoutSeconds, equals(45));
    });

    test('AudioConfig Gemini Live 双模式配置默认值与非法值安全降级自愈', () {
      // 1. 默认值验证
      const defaultConfig = AudioConfig();
      expect(defaultConfig.geminiLiveAdvancedMode,
          equals(AppConstants.defaultGeminiLiveAdvancedMode));
      expect(defaultConfig.geminiLiveThinkingLevel,
          equals(AppConstants.defaultGeminiLiveThinkingLevel));
      expect(defaultConfig.geminiLiveIncludeThoughts,
          equals(AppConstants.defaultGeminiLiveIncludeThoughts));

      // 2. 非法模式回退
      final invalidMode = AudioConfig.fromMap({
        'geminiLiveAdvancedMode': 'invalid_mode',
      });
      expect(invalidMode.geminiLiveAdvancedMode, equals('auto'));

      // 3. 非法思考级别回退
      final invalidLevel = AudioConfig.fromMap({
        'geminiLiveThinkingLevel': 'super_extreme',
      });
      expect(invalidLevel.geminiLiveThinkingLevel, equals('medium'));

      // 4. 空白与首尾空格自愈
      final trimmed = AudioConfig.fromMap({
        'geminiLiveAdvancedMode': '  advanced  ',
        'geminiLiveThinkingLevel': ' high ',
      });
      expect(trimmed.geminiLiveAdvancedMode, equals('advanced'));
      expect(trimmed.geminiLiveThinkingLevel, equals('high'));

      // 5. AppSettings 门面增量更新 applyMap / copyWithMap
      final s = AppSettings();
      expect(s.geminiLiveAdvancedMode, equals('auto'));
      expect(s.geminiLiveThinkingLevel, equals('medium'));
      expect(s.geminiLiveIncludeThoughts, isFalse);

      final updated = s.copyWithMap({
        'geminiLiveAdvancedMode': 'basic',
        'geminiLiveThinkingLevel': 'low',
        'geminiLiveIncludeThoughts': true,
      });
      expect(updated.geminiLiveAdvancedMode, equals('basic'));
      expect(updated.geminiLiveThinkingLevel, equals('low'));
      expect(updated.geminiLiveIncludeThoughts, isTrue);

      s.applyMap({
        'geminiLiveAdvancedMode': 'advanced',
        'geminiLiveThinkingLevel': 'high',
        'geminiLiveIncludeThoughts': true,
      });
      expect(s.geminiLiveAdvancedMode, equals('advanced'));
      expect(s.geminiLiveThinkingLevel, equals('high'));
      expect(s.geminiLiveIncludeThoughts, isTrue);
    });
  });
}
