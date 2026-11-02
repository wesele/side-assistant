import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/transcript_processor.dart';
import 'package:side_assistant/services/speech/voice_listening_service.dart';

import 'model_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 纯测试环境没有 record / audioplayers 原生实现，用 mock 让控制器能正常构造、唤醒与销毁。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (methodCall) async => 1,
  );
  HttpOverrides.global = null;

  /// 说明：
  /// - ttsEngine 用 'system'：'edge' 需要联网合成，测试里不可靠。
  ///   测试环境没有原生 TTS，_speakSentence 会抛 MissingPluginException 并被内部捕获，
  ///   但「已朗读文本」在真正播放之前就已登记，足以驱动回声拒识逻辑。
  /// - asrEngine 用 streaming：与本测试无关，只是避免每个用例都加载 239MB 的 SenseVoice。
  AppSettings buildSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
      );

  group('声学回声拒识（助手外放内容被麦克风回采）', () {
    late AssistantController controller;

    setUp(() {
      controller = AssistantController(
          settings: buildSettings(), enableDriverServer: false);
    });

    tearDown(() {
      controller.dispose();
    });

    test('外放内容被回采后不得当成用户语音', () async {
      const reply = '今天天气不错，适合出门散步';
      await controller.ttsService.speakImmediate(reply);
      expect(controller.ttsService.recentlySpokenText, contains('今天天气不错'));

      // 1) 完整回声
      await controller.processRecognizedText('今天天气不错，适合出门散步');
      expect(controller.lastRecognizedSpeech, isEmpty, reason: '完整回声必须被丢弃');
      expect(controller.status, equals(AssistantStatus.idle));

      // 2) 断句后只剩后半句的局部回声
      await controller.processRecognizedText('适合出门散步');
      expect(controller.lastRecognizedSpeech, isEmpty, reason: '局部回声必须被丢弃');

      // 3) 带标点、句尾略有偏差的首句回声
      await controller.processRecognizedText('今天天气不错。');
      expect(controller.lastRecognizedSpeech, isEmpty, reason: '带标点的回声必须被丢弃');
    });

    test('回声里恰好含开始词时也不得触发自我唤醒', () async {
      await controller.ttsService.speakImmediate('晓漫已经帮你设好闹钟了');

      await controller.processRecognizedText('晓漫已经帮你设好闹钟了');

      expect(controller.status, equals(AssistantStatus.idle),
          reason: '不得因回声进入倾听状态');
      expect(controller.isWakeWordMatched, isFalse);
    });

    test('用户真实的打断语音不会被误判为回声', () async {
      await controller.ttsService.speakImmediate('今天天气不错，适合出门散步');

      await controller.processRecognizedText('晓漫');

      expect(controller.status, equals(AssistantStatus.listeningContent),
          reason: '“晓漫”不在助手朗读内容中，必须被当作真实用户语音');
    });

    test('没有朗读内容时闸门完全不干预', () async {
      expect(controller.ttsService.recentlySpokenText, isEmpty);

      await controller.processRecognizedText('小曼 帮我查一下明天的天气');

      expect(controller.status, equals(AssistantStatus.listeningContent));
    });

    test('外放回声与用户“小曼”粘连成一句时，剥离回声并成功唤醒/打断', () async {
      await controller.ttsService.speakImmediate('量子力学是研究物质世界微观粒子运动规律的物理学分支');

      // 场景 1：前半截是外放回声，末尾是用户喊的“小曼”
      await controller.processRecognizedText('量子力学是研究物质世界小曼');
      expect(
        controller.status,
        equals(AssistantStatus.listeningContent),
        reason: '混在回声尾部的“小曼”应被剥离提取并成功触发倾听',
      );
      expect(controller.liveTranscript, isEmpty, reason: '打断后倾听缓冲应保持干净');
    });

    test('stripAssistantEcho 精准剥离头中尾混音且不误放行自激回声', () {
      final settings = buildSettings();
      final matcher = TriggerMatcher(
        settings: settings,
      );
      const spoken = '今天天气非常不错，非常适合出门散步和晒太阳';

      // 1. 纯回声（含同音误识“三步”）-> 空串
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '今天天气非常不错，非常适合出门散步',
          recentlySpokenText: spoken,
          triggerMatcher: matcher,
        ),
        isEmpty,
      );
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '非常适合出门三步',
          recentlySpokenText: spoken,
          triggerMatcher: matcher,
        ),
        isEmpty,
      );

      // 2. 句中夹杂“小曼” -> 只剩“小曼”
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '今天天气非常小曼非常适合出门',
          recentlySpokenText: spoken,
          triggerMatcher: matcher,
        ),
        equals('小曼'),
      );

      // 3. 句首“小曼” + 后跟外放回声 -> 只剩“小曼”
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '小曼今天天气非常不错',
          recentlySpokenText: spoken,
          triggerMatcher: matcher,
        ),
        equals('小曼'),
      );

      // 4. 助手自身朗读含“小曼”时，整句回声仍被完全剥离；但后续句段用户喊“小曼”仍能检出
      const spokenWithSelfName = '我是小曼，下面为您介绍量子力学与微观粒子的运动规律';
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '我是小曼下面为您介绍量子力学',
          recentlySpokenText: spokenWithSelfName,
          triggerMatcher: matcher,
        ),
        isEmpty,
      );
      expect(
        TranscriptProcessor.stripAssistantEcho(
          recognized: '量子力学小曼与微观粒子',
          recentlySpokenText: spokenWithSelfName,
          triggerMatcher: matcher,
        ),
        equals('小曼'),
      );
    });

    test('播报长语音期间外放连续不断（VAD 不切段），滚动短窗探针仍能实时识别“小曼”', () async {
      final settings = buildSettings();
      final fakeAsr = _FakeBargeInAsrService(settings: settings);
      final recognized = <String>[];

      final service = VoiceListeningService(
        asrService: fakeAsr,
        settings: settings,
        onTextRecognized: recognized.add,
        isStandbyMode: () => false,
        isPlayingMode: () => true,
      );

      await service.initializeVadForTest();
      addTearDown(service.dispose);

      // 构造持续 1.2 秒的非静音正弦波（无任何静音间隙，Silero VAD 不会切出完整段）
      final chunk = Float32List(3200); // 200ms @ 16kHz
      for (int i = 0; i < chunk.length; i++) {
        chunk[i] = 0.15;
      }

      for (int step = 0; step < 6; step++) {
        await service.feedAudioForTest(chunk);
      }

      expect(
        fakeAsr.probeCount,
        greaterThanOrEqualTo(1),
        reason: '连续外放超过 0.8s 未断句时，必须触发播报期滚动短窗探针',
      );
      expect(recognized, contains('量子力学是研究小曼'));
    }, skip: skipUnlessAsset(kSileroVad));
  });
}

class _FakeBargeInAsrService extends AsrService {
  @override
  final AppSettings settings;
  int probeCount = 0;

  _FakeBargeInAsrService({required this.settings});

  @override
  bool get isReady => true;

  @override
  Future<sherpa_onnx.VoiceActivityDetector?> createVad({
    double minSilenceDuration = 0.50,
    double minSpeechDuration = 0.25,
    double maxSpeechDuration = 30.0,
    double threshold = 0.40,
  }) {
    // 调高 threshold 使合成直流块不弹出 VAD 完整段，模拟连续外放期间 VAD 一直不切段的场景
    return super.createVad(
      minSilenceDuration: 10.0,
      minSpeechDuration: 5.0,
      maxSpeechDuration: 30.0,
      threshold: 0.99,
    );
  }

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async {
    probeCount++;
    return '量子力学是研究小曼';
  }
}
