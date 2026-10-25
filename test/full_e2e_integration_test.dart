import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/nlp/embedding_service.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';
import 'package:side_assistant/services/nlp/vector_math.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );
  HttpOverrides.global = null; // 允许集成测试发起真实网络请求

  group('1. 真实 NVIDIA Nemotron-3-Embed-1b 向量服务集成测试', () {
    late AppSettings settings;
    late RemoteOpenAiEmbeddingService embeddingService;

    setUp(() {
      settings = AppSettings(); // 默认即为 workbench 配置
      embeddingService = RemoteOpenAiEmbeddingService(settings: settings);
    });

    test('成功调用远程 Embedding 接口并返回 2048 维向量', () async {
      final vec = await embeddingService.getEmbedding('晓漫');
      expect(vec.length, equals(2048));
      expect(vec.any((v) => v != 0.0), isTrue);
    });

    test('同词向量自相似度为 1.0', () async {
      final vecA = await embeddingService.getEmbedding('晓漫');
      final vecB = await embeddingService.getEmbedding('晓漫');
      final sim = VectorMath.cosineSimilarity(vecA, vecB);
      expect(sim, closeTo(1.0, 0.001));
    });

    test('近义短语余弦相似度显著高于无关短语', () async {
      final vecStart = await embeddingService.getEmbedding('新起一个');
      final vecSimilar = await embeddingService.getEmbedding('重新开一个');
      final vecIrrelevant = await embeddingService.getEmbedding('红烧排骨的做法');

      final simSimilar = VectorMath.cosineSimilarity(vecStart, vecSimilar);
      final simIrrelevant = VectorMath.cosineSimilarity(vecStart, vecIrrelevant);

      expect(simSimilar, greaterThan(simIrrelevant));
      expect(simSimilar, greaterThan(0.25));
    });
  });

  group('2. 真实 DeepSeek-V4.1-Flash 大模型服务集成测试', () {
    late AppSettings settings;
    late LlmService llmService;

    setUp(() {
      settings = AppSettings();
      llmService = LlmService(settings: settings);
    });

    test('流式请求 DeepSeek 成功返回有效中文文本', () async {
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

    test('多轮对话上下文连贯性验证（记忆力测试）', () async {
      final controller = AssistantController(settings: settings);

      // 第一轮：告知秘密名字
      await controller.simulateUserInput('晓漫 我的幸运数字是7788 回答');
      // 等待思考完成
      int waitCount = 0;
      while (controller.status != AssistantStatus.idle && waitCount < 50) {
        await Future.delayed(const Duration(milliseconds: 200));
        waitCount++;
      }

      expect(controller.messages.length, greaterThanOrEqualTo(2));
      final firstReply = controller.messages.last.content;
      expect(firstReply.isNotEmpty, isTrue);

      // 第二轮：追问刚才的信息，验证上下文是否完整保留
      await controller.simulateUserInput('晓漫 我的幸运数字是多少 回答');
      waitCount = 0;
      while (controller.status != AssistantStatus.idle && waitCount < 50) {
        await Future.delayed(const Duration(milliseconds: 200));
        waitCount++;
      }

      expect(controller.messages.length, greaterThanOrEqualTo(4));
      final secondReply = controller.messages.last.content;
      // 大模型应该在第二轮中根据前文准确回答出 7788
      expect(secondReply, contains('7788'));
    });
  });

  group('3. 触发词双层匹配与指令剥离端到端测试', () {
    late AppSettings settings;
    late TriggerMatcher matcher;

    setUp(() async {
      settings = AppSettings();
      final emb = RemoteOpenAiEmbeddingService(settings: settings);
      matcher = TriggerMatcher(settings: settings, embeddingService: emb);
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

  group('4. AssistantController 全状态机闭环与“新起一个”本地重置测试', () {
    late AppSettings settings;
    late AssistantController controller;

    setUp(() {
      settings = AppSettings();
      controller = AssistantController(settings: settings);
    });

    test('输入“新起一个”立即本地重置会话，不调用大模型', () async {
      // 预先写入一条历史消息
      await controller.simulateUserInput('晓漫 你好 回答');
      int waitCount = 0;
      while (controller.status != AssistantStatus.idle && waitCount < 50) {
        await Future.delayed(const Duration(milliseconds: 200));
        waitCount++;
      }
      expect(controller.messages.isNotEmpty, isTrue);
      final oldSessionId = controller.currentSessionId;

      // 发出“新起一个”指令
      await controller.simulateUserInput('新起一个');

      // 验证上下文已被彻底重置
      expect(controller.messages.isEmpty, isTrue);
      expect(controller.currentSessionId, isNot(equals(oldSessionId)));
      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.statusHint, contains('已开启全新会话'));
    });

    test('超时自动取消保护机制', () async {
      // 调整超时为 1 秒以便快速测试
      controller.settings.silenceTimeoutSeconds = 1;

      // 只说开始词唤醒，不说结束词
      await controller.simulateUserInput('晓漫');
      expect(controller.status, equals(AssistantStatus.listeningContent));

      // 等待 1.2 秒触发超时
      await Future.delayed(const Duration(milliseconds: 1300));

      // 验证自动退出倾听，返回待机并提示已取消
      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.statusHint, contains('已自动取消'));
    });
  });
}
