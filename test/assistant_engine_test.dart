import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock method channel calls for audio plugins in headless test environment
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

  AppSettings buildTestSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: false,
        silenceTimeoutSeconds: 12,
      );

  group('AssistantEngine 核心领域引擎测试', () {
    late AssistantEngine engine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      engine = AssistantEngine(
        settings: buildTestSettings(),
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    tearDown(() {
      engine.dispose();
    });

    test('1. 初始化状态正确性与基础契约验证', () {
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.lastRecognizedSpeech, isEmpty);
      expect(engine.isWakeWordMatched, isFalse);
      expect(engine.isInContinuousMode, isFalse);
      expect(engine.settings.startWord, equals('晓漫'));
      expect(engine.asrService, isNotNull);
      expect(engine.voiceService, isNotNull);
    });

    test('2. 类型化事件流 (engine.events) 广播与监听机制测试', () async {
      final receivedEvents = <AssistantEngineEvent>[];
      final sub = engine.events.listen(receivedEvents.add);

      // 触发轻滴声提示音
      await engine.playAcknowledgeBeep();

      // 模拟唤醒输入
      await engine.processRecognizedText('小曼 帮我查一下天气');

      // 等待事件分发
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        receivedEvents.any((e) => e is SoundEffectTriggeredEvent),
        isTrue,
        reason: '应该发射 SoundEffectTriggeredEvent',
      );
      expect(
        receivedEvents.any((e) =>
            e is StatusChangedEvent &&
            e.status == AssistantStatus.listeningContent),
        isTrue,
        reason: '应该发射从 idle 到 listeningContent 的 StatusChangedEvent',
      );
      expect(
        receivedEvents.any((e) => e is TranscriptUpdatedEvent),
        isTrue,
        reason: '应该发射 TranscriptUpdatedEvent',
      );

      await sub.cancel();
    });

    test('3. 唤醒词检测与状态机变迁（idle -> listeningContent）', () async {
      final initialBeeps = engine.acknowledgeBeepCount;

      await engine.processRecognizedText('小曼 现在的几点了');

      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, contains('现在的几点了'));
      expect(engine.isWakeWordMatched, isTrue);
      expect(engine.acknowledgeBeepCount, greaterThan(initialBeeps));
    });

    test('4. 二次呼唤唤醒词时清空前文草稿（Re-wake Word Discard）', () async {
      // 首次唤醒
      await engine.processRecognizedText('小曼 今天天气如何');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, equals('今天天气如何'));

      // 再次唤醒输入新指令
      await engine.processRecognizedText('小曼 帮我写一首诗');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, isNot(contains('今天天气如何')));
      expect(engine.liveTranscript, equals('帮我写一首诗'));

      // 单独喊唤醒词，草稿彻底清空
      await engine.processRecognizedText('小曼');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, isEmpty);
    });

    test('5. 声学回声拒识（助手外放内容被麦克风回采时丢弃）', () async {
      engine.settings.enableTtsPlayback = true;
      const assistantReply = '北京今天晴天，气温十五度到二十五度';
      await engine.ttsService.speakImmediate(assistantReply);
      expect(engine.ttsService.recentlySpokenText, contains('北京今天晴天'));

      // 麦克风回采整句回声，状态机必须保持待机，绝不能被外放误唤醒
      await engine.processRecognizedText(assistantReply);
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
    });

    test('6. 两遍解码裁决算法 chooseFinalTranscript 静态测试', () {
      // 离线结果覆盖流式文本时优先采用离线结果
      final chosen = AssistantEngine.chooseFinalTranscript(
        '今天几号',
        '今天几号？',
      );
      expect(chosen, equals('今天几号？'));

      // 若流式文本更完整，保留流式长文本
      final keepLive = AssistantEngine.chooseFinalTranscript(
        '明天早上八点叫我起床并提醒我带雨伞',
        '明天早上八点',
      );
      expect(keepLive, equals('明天早上八点叫我起床并提醒我带雨伞'));

      // 两者互补时按重叠关系合并
      final merged = AssistantEngine.chooseFinalTranscript(
        '今天天气',
        '天气怎么样',
      );
      expect(merged, equals('今天天气怎么样'));
    });

    test('7. 领域化配置局部热重载 (updateSettings) 隔离性测试', () async {
      final initialVoiceService = engine.voiceService;
      final initialSpeakerService = engine.speakerVerificationService;

      final updatedSettings = AppSettings.fromMap(engine.settings.toMap())
        ..openAiModel = 'gpt-4o-mini'
        ..openAiBaseUrl = 'https://api.example.com/v1';

      await engine.updateSettings(updatedSettings);

      // LLM 配置变更不得影响或重建底层音频与声纹服务
      expect(identical(engine.voiceService, initialVoiceService), isTrue);
      expect(
        identical(engine.speakerVerificationService, initialSpeakerService),
        isTrue,
      );
      expect(engine.settings.openAiModel, equals('gpt-4o-mini'));
    });

    test('8. 新起会话 (startNewSession) 重置状态与会话上下文', () async {
      final oldSessionId = engine.currentSessionId;

      await engine.startNewSession(playVoice: false);

      expect(engine.currentSessionId, isNot(equals(oldSessionId)));
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.messages, isEmpty);
    });

    test('9. 语义驱动方法 triggerWake / resetToIdle / executeIntent 测试', () async {
      // triggerWake
      await engine.triggerWake(wakeWord: '小曼');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.isWakeWordMatched, isTrue);

      // resetToIdle
      await engine.resetToIdle();
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);

      // executeIntent
      await engine.executeIntent('wake', parameters: {'word': '晓漫'});
      expect(engine.status, equals(AssistantStatus.listeningContent));

      await engine.executeIntent('reset_to_idle');
      expect(engine.status, equals(AssistantStatus.idle));
    });

    test('10. 资源释放与 disposeAsync 无泄露验证', () async {
      final testEngine = AssistantEngine(
        settings: buildTestSettings(),
        enableDriverServer: false,
      );

      bool eventStreamClosed = false;
      testEngine.events.listen(
        (_) {},
        onDone: () => eventStreamClosed = true,
      );

      await testEngine.disposeAsync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(eventStreamClosed, isTrue);
    });
  });
}
