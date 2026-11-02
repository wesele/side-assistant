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
      };

      final settings = AppSettings.fromMap(customMap);

      // 验证各个领域对象正确反序列化
      expect(settings.audio.startWord, equals('自定义唤醒词'));
      expect(settings.audio.ownerSpeakerEmbeddings.length, equals(2));
      expect(
          settings.llm.openAiApiKey, equals('sk-custom-secret-key-123456789'));
      expect(settings.llm.disableThinking, isTrue);
      expect(settings.tts.playbackVolume, equals(95));
      expect(settings.tts.ttsSpeed, equals(1.25));
      expect(settings.vision.nanoBleAddress, equals('AA:BB:CC:DD:EE:FF'));
      expect(settings.server.webAccessPassword, equals('SuperSecretPassword'));

      // 验证平坦 getter 转发
      expect(settings.startWord, equals('自定义唤醒词'));
      expect(settings.openAiApiKey, equals('sk-custom-secret-key-123456789'));
      expect(settings.playbackVolume, equals(95));
      expect(settings.webAccessPassword, equals('SuperSecretPassword'));

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

    test('AppSettings copyWithMap 与 applyMap 增量更新验证', () {
      final s = AppSettings(
        startWord: '原有唤醒词',
        openAiModel: '原有模型',
        playbackVolume: 50,
      );

      final delta = {
        'startWord': '新唤醒词',
        'openAiModel': '新模型',
        'playbackVolume': 85,
      };

      // 1. 不可变更新 copyWithMap
      final updated = s.copyWithMap(delta);
      expect(updated.startWord, equals('新唤醒词'));
      expect(updated.openAiModel, equals('新模型'));
      expect(updated.playbackVolume, equals(85));
      expect(s.startWord, equals('原有唤醒词')); // 原对象不变

      // 2. 就地更新 applyMap
      s.applyMap(delta);
      expect(s.startWord, equals('新唤醒词'));
      expect(s.openAiModel, equals('新模型'));
      expect(s.playbackVolume, equals(85));
    });
  });
}
