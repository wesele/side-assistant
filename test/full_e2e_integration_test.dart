import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );
  HttpOverrides.global = null; // 允许集成测试发起真实网络请求

  group('1. 真实 DeepSeek 大模型服务集成测试', () {
    late AppSettings settings;
    late LlmService llmService;

    setUp(() {
      settings = AppSettings();
      llmService = LlmService(settings: settings);
    });

    test('流式请求 DeepSeek 成功返回有效中文文本', () async {
      if (settings.openAiApiKey.isEmpty) {
        return;
      }
      final stream = llmService.sendChatStream(
        history: [],
        newUserContent: '请只回答“测试成功”这四个字，不要输出任何其他内容。',
      );

      final buffer = StringBuffer();
      await for (final token in stream) {
        buffer.write(token);
      }

      final reply = buffer.toString().trim();
      expect(reply.isNotEmpty, isTrue);
      expect(reply, contains('测试成功'));
    });
  });

  group('2. 触发词匹配与指令剥离测试', () {
    late AppSettings settings;
    late TriggerMatcher matcher;

    setUp(() async {
      settings = AppSettings();
      matcher = TriggerMatcher(settings: settings);
      await matcher.warmUp();
    });

    test('综合扫描优先命中新起会话词', () async {
      final res = await matcher.checkWakeAndControlWords('新起一个');
      expect(res.type, equals(TriggerType.reset));
    });

    test('开始词拼音容错判定命中', () async {
      final res = await matcher.checkStartWord('小曼今天天气怎么样');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
    });

    test('结束词精准剥离提炼提问内容', () {
      final prompt = matcher.stripEndWord('帮我查一下明天的汇率是多少回答');
      expect(prompt, equals('帮我查一下明天的汇率是多少'));
    });

    test('多词配置：开始词/结束词/新起会话词都能按分号配置多个', () async {
      settings.startWord = '晓漫；小助手';
      settings.endWord = '回答；完毕';
      settings.resetWord = '新起一个；重新开始';
      await matcher.warmUp();

      final start = await matcher.checkStartWord('小助手 今天天气怎么样');
      expect(start.type, equals(TriggerType.start));

      final end = await matcher.checkEndWord('帮我查一下明天的日程完毕');
      expect(end.type, equals(TriggerType.end));

      final reset = await matcher.checkResetWord('重新开始');
      expect(reset.type, equals(TriggerType.reset));

      expect(matcher.stripEndWord('明天的日程完毕'), equals('明天的日程'));
    });

    test('新起会话词的语义/同义说法也能命中', () async {
      await matcher.warmUp();
      for (final text in ['新启一个', '新建会话', '换个话题']) {
        final res = await matcher.checkResetWord(text);
        expect(
          res.type,
          equals(TriggerType.reset),
          reason: '“$text” 应命中新起会话词',
        );
      }
    });
  });
}
