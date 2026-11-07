import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/services/llm/llm_service.dart';

/// 可受控的模拟 LLM 服务，避免在单元测试中发起真实外部网络请求并可精确控制延迟
class MockSpeechLlmService extends LlmService {
  int sendChatStreamCount = 0;
  final List<String> receivedQueries = [];
  bool holdResponse = false;
  Completer<void>? responseCompleter;

  MockSpeechLlmService(AppSettings settings) : super(settings: settings);

  @override
  Stream<String> sendChatStream({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  }) async* {
    sendChatStreamCount++;
    receivedQueries.add(newUserContent);
    if (holdResponse && responseCompleter != null) {
      await responseCompleter!.future;
    }
    yield '{"intent":"chat","reply":"已为您处理：$newUserContent"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock audio/TTS method channels in headless test environment
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

  AppSettings buildTestSettings({
    String startWordMode = AppConstants.startWordModeEnabled,
    bool enableTwoPass = false,
    bool enableTtsPlayback = true,
    bool enableBargeIn = true,
    double silenceTimeoutSeconds = 10,
  }) =>
      AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: enableTwoPass,
        enableTtsPlayback: enableTtsPlayback,
        enableBargeIn: enableBargeIn,
        silenceTimeoutSeconds: silenceTimeoutSeconds,
        startWordMode: startWordMode,
      );

  group('Group 1: 唤醒词二次触发草稿清空对抗测试 (Re-Wake Word Discard Stress)', () {
    late AssistantEngine engine;
    late MockSpeechLlmService mockLlm;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings();
      mockLlm = MockSpeechLlmService(settings);
      engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() {
      engine.dispose();
    });

    test('1.1 单次唤醒后草稿累积，再次输入“唤醒词+新提问”彻底抹除旧草稿', () async {
      await engine.processRecognizedText('小曼 帮我查一下明天的北京天气');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, equals('帮我查一下明天的北京天气'));
      expect(engine.isWakeWordMatched, isTrue);

      await engine.processRecognizedText('小曼 帮我定明天早上七点的闹钟');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, equals('帮我定明天早上七点的闹钟'));
      expect(engine.liveTranscript, isNot(contains('北京天气')));
    });

    test('1.2 倾听状态下单独喊唤醒词“小曼”，草稿彻底归空', () async {
      await engine.processRecognizedText('小曼 帮我订一张去深圳的高铁票');
      expect(engine.liveTranscript, equals('帮我订一张去深圳的高铁票'));

      await engine.processRecognizedText('小曼');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, isEmpty);
    });

    test('1.3 高频连续突发唤醒词连发与草稿覆盖压力测试', () async {
      final inputs = [
        '小曼 第一次输入文本',
        '小曼 第二次改口输入',
        '小曼 第三次又反悔了',
        '小曼 第四次又改口了',
        '小曼',
      ];

      for (int i = 0; i < inputs.length; i++) {
        final text = inputs[i];
        await engine.processRecognizedText(text);
        expect(
          engine.status,
          equals(AssistantStatus.listeningContent),
          reason: 'Failed on iteration $i: "$text", status is ${engine.status}',
        );
      }

      expect(engine.liveTranscript, isEmpty);
    });

    test('1.4 倾听状态下检测到一键指令（One-Shot Command），立即抹除草稿并切入思考', () async {
      final events = <AssistantEngineEvent>[];
      final sub = engine.events.listen(events.add);

      await engine.processRecognizedText('小曼 刚才那句话不算');
      expect(engine.liveTranscript, equals('刚才那句话不算'));

      // 听到一键指令（含开始词与结束词）
      await engine.processRecognizedText('小曼现在几点了回答');

      expect(engine.liveTranscript, isEmpty);
      expect(
        events.any((e) =>
            e is StatusChangedEvent && e.status == AssistantStatus.thinking),
        isTrue,
        reason: '应该发射向 thinking 转变的状态变更事件',
      );
      expect(mockLlm.sendChatStreamCount, equals(1));
      expect(mockLlm.receivedQueries.last, equals('现在几点了'));

      await sub.cancel();
    });

    test('1.5 倾听状态下检测到会话重置口令（“新起一个”），清空草稿并重设 Session', () async {
      await engine.processRecognizedText('小曼 我们之前聊到哪里了');
      final oldSessionId = engine.currentSessionId;

      await engine.processRecognizedText('新起一个');

      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.currentSessionId, isNot(equals(oldSessionId)));
    });

    test('1.6 流式 partialTranscript 与新唤醒词的并发交织竞态测试', () async {
      await engine.processRecognizedText('小曼 今天天气');
      expect(engine.liveTranscript, equals('今天天气'));

      await engine.processPartialTranscript('今天天气怎么样');
      expect(engine.liveTranscript, equals('今天天气怎么样'));

      await engine.processRecognizedText('小曼 几点了');
      expect(engine.liveTranscript, equals('几点了'));
    });

    test('1.7 倾听状态下再次听到近音词（如“小麦”）也应抛弃前文草稿并接收新内容', () async {
      await engine.processRecognizedText('小曼 查一下明天的火车票');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, equals('查一下明天的火车票'));

      // 再次听到近音词“小麦 帮我定个闹钟”
      await engine.processRecognizedText('小麦 帮我定个闹钟');
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, isNot(contains('火车票')));
      expect(engine.liveTranscript, equals('帮我定个闹钟'));
    });
  });

  group('Group 2: 声学回声拒识对抗压力测试 (Acoustic Echo Rejection Stress)', () {
    late AssistantEngine engine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      engine = AssistantEngine(
        settings: buildTestSettings(enableTtsPlayback: true),
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() {
      engine.dispose();
    });

    test('2.1 完整外放文本被麦克风回采时绝对阻断（零误唤醒）', () async {
      const ttsOutput = '根据气象台发布的天气预报，北京今天晴间多云，适合户外运动';
      await engine.ttsService.speakImmediate(ttsOutput);
      expect(engine.ttsService.recentlySpokenText, contains('北京今天晴间多云'));

      await engine.processRecognizedText(ttsOutput);

      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.isWakeWordMatched, isFalse);
    });

    test('2.2 外放长句被 VAD 切割为多段局部碎片回采的逐段阻断', () async {
      const ttsOutput = '人工智能模型正在快速迭代，端侧大模型将在智能穿戴设备中广泛应用';
      await engine.ttsService.speakImmediate(ttsOutput);

      final echoFragments = [
        '人工智能模型正在快速迭代',
        '端侧大模型将在智能穿戴',
        '设备中广泛应用',
        '智能穿戴设备中广泛应用。',
      ];

      for (final fragment in echoFragments) {
        await engine.processRecognizedText(fragment);
        expect(engine.status, equals(AssistantStatus.idle));
        expect(engine.liveTranscript, isEmpty);
      }
    });

    test('2.3 助手外放台词中包含自身唤醒词（如“我是小曼，为您服务”）时的自激防御测试', () async {
      const selfIntro = '您好，我是小曼，很高兴为您服务，请问有什么可以帮您？';
      await engine.ttsService.speakImmediate(selfIntro);

      await engine.processRecognizedText('我是小曼很高兴为您服务');
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.isWakeWordMatched, isFalse);

      await engine.processRecognizedText('您好我是小曼');
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.isWakeWordMatched, isFalse);
    });

    test('2.4 外放回声末尾粘连用户真实唤醒打断词时的精准剥离与唤醒', () async {
      const ttsOutput = '量子力学是描述微观物质结构运动规律的物理学基础理论';
      await engine.ttsService.speakImmediate(ttsOutput);

      await engine.processRecognizedText('规律的物理学基础理论小曼 帮我查天气');

      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.isWakeWordMatched, isTrue);
      expect(engine.liveTranscript, isNot(contains('物理学基础理论')));
    });

    test('2.5 连续 50 次高频回声注入时零误唤醒、零状态漂移', () async {
      const ttsOutput = '正在为您播放音乐，请稍候';
      await engine.ttsService.speakImmediate(ttsOutput);

      for (int i = 0; i < 50; i++) {
        await engine.processRecognizedText(ttsOutput);
      }

      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.isWakeWordMatched, isFalse);
    });
  });

  group('Group 3: 播报期间打断（Barge-In）状态机变迁对抗测试 (Barge-In Stress)', () {
    late AssistantEngine engine;
    late MockSpeechLlmService mockLlm;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings =
          buildTestSettings(enableTtsPlayback: true, enableBargeIn: true);
      mockLlm = MockSpeechLlmService(settings);
      engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() {
      engine.dispose();
    });

    test('3.1 播报中用户说纯停止口令（“停止”/“闭嘴”/“退下”），即刻静音并退回 idle', () async {
      engine.ttsService.enqueueSentence('正在为您播报一段非常冗长的小说段落...');
      expect(engine.ttsService.isSpeaking, isTrue);

      await engine.processRecognizedText('停止');

      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.ttsService.isSpeaking, isFalse);
    });

    test('3.2 播报中用户单独喊唤醒词（“小曼”）打断播报，即刻静音并切入倾听', () async {
      engine.ttsService.enqueueSentence('明天天气温度为十八度到二十六度，偏北风三到四级...');
      expect(engine.ttsService.isSpeaking, isTrue);

      await engine.processRecognizedText('小曼');

      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, isEmpty);
      expect(engine.isWakeWordMatched, isTrue);
      expect(engine.ttsService.isSpeaking, isFalse);
    });

    test('3.3 播报中用户说唤醒词带新问题（“小曼 换一首歌”），即刻静音并捕获新问题', () async {
      engine.ttsService.enqueueSentence('正在为您播放轻音乐专辑中的第一首歌曲...');
      expect(engine.ttsService.isSpeaking, isTrue);

      await engine.processRecognizedText('小曼 换一首歌');

      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, equals('换一首歌'));
      expect(engine.isWakeWordMatched, isTrue);
      expect(engine.ttsService.isSpeaking, isFalse);
    });

    test('3.4 关闭 enableBargeIn 时打断指令无效', () async {
      engine.settings.enableBargeIn = false;
      engine.ttsService.enqueueSentence('正在为您播报不可打断的警报语音...');
      expect(engine.ttsService.isSpeaking, isTrue);

      final statusBefore = engine.status;

      await engine.processRecognizedText('停止');

      expect(engine.status, equals(statusBefore));
      expect(engine.ttsService.isSpeaking, isTrue);
    });

    test('3.5 连续高频并发打断指令不发生异常或死锁', () async {
      engine.ttsService.enqueueSentence('持续播报内容...');
      expect(engine.ttsService.isSpeaking, isTrue);

      final bargeInCommands = [
        '小曼',
        '停止',
        '小曼 别说了',
        '暂停',
        '小曼 重新开始',
      ];

      for (final cmd in bargeInCommands) {
        await engine.processRecognizedText(cmd);
      }

      expect(
        engine.status == AssistantStatus.idle ||
            engine.status == AssistantStatus.listeningContent,
        isTrue,
      );
      expect(engine.ttsService.isSpeaking, isFalse);
    });
  });

  group('Group 4: 静音超时与连续对话生命周期及定时器防泄漏测试 (Timer & Lifecycle Stress)', () {
    late AssistantEngine engine;
    late MockSpeechLlmService mockLlm;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings(silenceTimeoutSeconds: 1);
      mockLlm = MockSpeechLlmService(settings);
      engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() {
      engine.dispose();
    });

    test('4.1 唤醒后无后续输入，静音定时器到期平滑退回待机', () async {
      await engine.processRecognizedText('小曼');
      expect(engine.status, equals(AssistantStatus.listeningContent));

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
    });

    test('4.2 持续推入流式文本重置静音定时器，不会过早超时', () async {
      await engine.processRecognizedText('小曼');
      expect(engine.status, equals(AssistantStatus.listeningContent));

      for (int i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await engine.processPartialTranscript('测试文本第 $i 句');
        expect(
          engine.status,
          equals(AssistantStatus.listeningContent),
          reason: '流式输入期间不应触发静音超时退回待机',
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        engine.status == AssistantStatus.idle ||
            engine.status == AssistantStatus.thinking ||
            engine.status == AssistantStatus.playing,
        isTrue,
      );
    });

    test('4.3 50 次极速交替 triggerWake 与 resetToIdle 压力测试（定时器取消与零泄漏）', () async {
      for (int i = 0; i < 50; i++) {
        await engine.triggerWake(wakeWord: '小曼');
        expect(engine.status, equals(AssistantStatus.listeningContent));
        await engine.resetToIdle();
        expect(engine.status, equals(AssistantStatus.idle));
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.status, equals(AssistantStatus.idle));
      expect(engine.liveTranscript, isEmpty);
    });

    test('4.4 运行态定时器在 disposeAsync 后彻底释放', () async {
      final testEngine = AssistantEngine(
        settings: buildTestSettings(silenceTimeoutSeconds: 1),
        enableDriverServer: false,
      );

      await testEngine.triggerWake(wakeWord: '小曼');
      expect(testEngine.status, equals(AssistantStatus.listeningContent));

      await testEngine.disposeAsync();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      // 验证未抛出任何未捕获的定时器异常
    });
  });

  group('Group 5: 状态机规范与模式对抗验证 (State Machine Invariants & Mode Compliance)',
      () {
    test('5.1 启用模式 (startWordMode: enabled)：未喊唤醒词前外界杂音绝对不误进入倾听', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AssistantEngine(
        settings: buildTestSettings(
          startWordMode: AppConstants.startWordModeEnabled,
        ),
        enableDriverServer: false,
      );
      addTearDown(engine.dispose);

      expect(engine.status, equals(AssistantStatus.idle));

      await engine.processRecognizedText('今天中午吃什么');

      expect(
        engine.status,
        equals(AssistantStatus.idle),
        reason: '在显式唤醒词模式下，未匹配到开始词不得进入倾听状态',
      );
      expect(engine.isWakeWordMatched, isFalse);
    });

    test('5.2 关闭模式 (startWordMode: disabled)：无唤醒词直接说话即可进入倾听', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AssistantEngine(
        settings: buildTestSettings(
          startWordMode: AppConstants.startWordModeDisabled,
        ),
        enableDriverServer: false,
      );
      addTearDown(engine.dispose);

      expect(engine.isWakeWordRequired, isFalse);

      await engine.processRecognizedText('今天天气如何');

      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.liveTranscript, contains('今天天气如何'));
    });

    test('5.3 自动模式 (startWordMode: auto) 待机期规范：首轮未喊唤醒词时不得误唤醒', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AssistantEngine(
        settings: buildTestSettings(
          startWordMode: AppConstants.startWordModeAuto,
        ),
        enableDriverServer: false,
      );
      addTearDown(engine.dispose);

      expect(engine.isInContinuousMode, isFalse);
      expect(engine.isWakeWordRequired, isTrue);

      await engine.processRecognizedText('今天股票涨了吗');

      expect(
        engine.status,
        equals(AssistantStatus.idle),
        reason: '自动模式下尚未唤醒前，普通未包含唤醒词的语音不得触发倾听',
      );
    });
  });
}
