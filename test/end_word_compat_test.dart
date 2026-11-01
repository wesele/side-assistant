import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 无头测试环境：屏蔽录音与音频播放相关的原生通道
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

  late AppSettings settings;
  late TriggerMatcher matcher;

  setUp(() {
    settings = AppSettings(
      startWord: '晓漫',
      endWord: '回答',
      resetWord: '新起一个',
      similarityThreshold: 0.80,
    );
    matcher = TriggerMatcher(
      settings: settings,
    );
  });

  group('结束词内置兼容词簇（同音/近义收尾指令）', () {
    test('默认结束词“回答”会自动生成同音与近义兼容别名', () {
      final aliases = matcher.endWordAliases;
      expect(aliases, contains('回话'));
      expect(aliases, contains('请解答'));
      expect(aliases, contains('答复一下'));
      expect(aliases, isNot(contains('回答')));
    });

    test('generateEndWordVariants 返回含自身的完整兼容簇', () {
      final variants = matcher.generateEndWordVariants('回答');
      expect(variants, contains('回答'));
      expect(variants, contains('请回答'));
      expect(variants, contains('回话'));
    });

    test('近义收尾词“请解答”被识别为结束词', () async {
      final res = await matcher.checkEndWord('今天天气怎么样请解答');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.end));
      expect(res.matchedText, equals('请解答'));
    });

    test('近音收尾词“回话”被识别为结束词', () async {
      final res = await matcher.checkEndWord('今天几号回话');
      expect(res.isMatched, isTrue);
      expect(res.matchedText, equals('回话'));
    });

    test('兼容别名同样支持精确剥离提问内容', () {
      expect(matcher.stripEndWord('今天天气怎么样请解答'), equals('今天天气怎么样'));
      expect(matcher.stripEndWord('帮我写一首诗 请回答。'), equals('帮我写一首诗'));
    });

    test('别名词后带少量尾随杂音仍可命中（ASR 多听出的语气词/标点）', () async {
      final res = await matcher.checkEndWord('今天几号请解答。');
      expect(res.isMatched, isTrue);
    });
  });

  group('结束词兼容性不得造成句中误截断', () {
    test('句中出现的近义短语不应被当成结束词', () async {
      // “解答一下”出现在句中且后面还有内容，属于正常提问的一部分
      final res = await matcher.checkEndWord('帮我解答一下我的疑惑');
      expect(res.isMatched, isFalse);
    });

    test('完全无关的语句不应命中结束词', () async {
      final res = await matcher.checkEndWord('今天天气怎么样');
      expect(res.isMatched, isFalse);
    });

    test('一句流中，结束词出现在中间时以句中内容为准（不被尾随杂音规则误伤）', () async {
      // 开始词 + 内容 + 别名结束词
      final oneShot = await matcher.extractOneShotCommand('小曼 帮我写一首诗 请解答');
      expect(oneShot, isNotNull);
      expect(oneShot!.promptContent, equals('帮我写一首诗'));
    });
  });

  group('AssistantController 结束词兼容状态机', () {
    test('倾听中说出近义收尾词“请解答”也会结束录音并发送', () async {
      final controller = AssistantController(
        settings: AppSettings(
          startWord: '晓漫',
          endWord: '回答',
          resetWord: '新起一个',
          enablePromptTone: true,
          enableTtsPlayback: false,
        ),
        enableDriverServer: false,
      );

      await controller.processRecognizedText('小曼');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.acknowledgeBeepCount, equals(1));

      await controller.processRecognizedText('今天几号请解答');
      // 命中结束词兼容别名，再次播放提示音（累计 2 次）
      expect(controller.acknowledgeBeepCount, equals(2));

      controller.dispose();
    });

    test('仅听到结束词、没有提问内容时应返回待机且不发送（带明确状态提示）', () async {
      final controller = AssistantController(
        settings: AppSettings(
          startWord: '晓漫',
          endWord: '回答',
          resetWord: '新起一个',
          enablePromptTone: true,
          enableTtsPlayback: false,
        ),
        enableDriverServer: false,
      );

      await controller.processRecognizedText('小曼');
      expect(controller.acknowledgeBeepCount, equals(1));

      await controller.processRecognizedText('回答');
      // 无内容 => 回到待机，且不会触发“发送”提示音
      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.acknowledgeBeepCount, equals(1));

      controller.dispose();
    });
  });

  group('流式识别断句复位后的内容接续（防止丢失提问内容导致不发送）', () {
    test('相邻两次流式结果按重叠关系合并，而非直接覆盖', () {
      // 常规增长：新结果包含旧结果
      expect(
        AssistantController.mergeStreamingTranscript('今天几号', '今天几号回答'),
        equals('今天几号回答'),
      );
      // 断句复位后开启的新片段：必须接续保留，不能覆盖丢失
      expect(
        AssistantController.mergeStreamingTranscript('今天几号', '回答'),
        equals('今天几号 回答'),
      );
      // 存在重叠时的平滑拼接
      expect(
        AssistantController.mergeStreamingTranscript('今天天气', '气怎么样'),
        equals('今天天气怎么样'),
      );
      // 识别回退（新结果更短）时保留更完整的旧文本
      expect(
        AssistantController.mergeStreamingTranscript('今天天气怎么样', '今天天气'),
        equals('今天天气怎么样'),
      );
    });

    test('断句复位后仍能凭接续的内容正确命中结束词', () async {
      final merged = AssistantController.mergeStreamingTranscript('今天几号', '回答');
      final res = await matcher.checkEndWord(merged);
      expect(res.isMatched, isTrue);
      expect(merged, equals('今天几号 回答'));
    });

    test('控制器在倾听态下跨两次识别结果保留前文内容', () async {
      final controller = AssistantController(
        settings: AppSettings(
          startWord: '晓漫',
          endWord: '回答',
          resetWord: '新起一个',
          asrEngine: 'streaming',
          enableTtsPlayback: false,
        ),
        enableDriverServer: false,
      );

      await controller.processRecognizedText('晓漫 今天几号');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, equals('今天几号'));

      // 模拟流式 ASR 命中端点复位后又识别到新片段，前文不得丢失
      await controller.processRecognizedText('好');
      expect(controller.liveTranscript, equals('今天几号 好'));

      controller.dispose();
    });

    test('先说“小曼听得到吗”停顿再说“回答。”（含并发触发）必须正确发送“听得到吗”', () async {
      final controller = AssistantController(
        settings: AppSettings(
          startWord: '晓漫',
          endWord: '回答',
          resetWord: '新起一个',
          enablePromptTone: true,
          enableTtsPlayback: false,
        ),
        enableDriverServer: false,
      );

      // 模拟两段识别结果连续或并发进入控制器
      final f1 = controller.processRecognizedText('小曼听得到吗');
      final f2 = controller.processRecognizedText('回答。');
      await Future.wait([f1, f2]);

      // 唤醒 1 次 + 结束词提交 1 次 = 2 次提示音，且用户消息“听得到吗”已入列
      expect(controller.acknowledgeBeepCount, equals(2));
      expect(controller.messages, isNotEmpty);
      expect(controller.messages.first.role, equals('user'));
      expect(controller.messages.first.content, equals('听得到吗'));

      controller.dispose();
    });
  });
}
