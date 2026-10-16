import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/embedding_service.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';
import 'package:side_assistant/services/nlp/vector_math.dart';

void main() {
  group('VectorMath 测试', () {
    test('相同向量余弦相似度应为 1.0', () {
      final vecA = [1.0, 2.0, 3.0];
      final sim = VectorMath.cosineSimilarity(vecA, vecA);
      expect(sim, closeTo(1.0, 0.0001));
    });

    test('正交向量余弦相似度应为 0.0', () {
      final vecA = [1.0, 0.0];
      final vecB = [0.0, 1.0];
      final sim = VectorMath.cosineSimilarity(vecA, vecB);
      expect(sim, closeTo(0.0, 0.0001));
    });

    test('相反向量余弦相似度应为 -1.0', () {
      final vecA = [1.0, 2.0];
      final vecB = [-1.0, -2.0];
      final sim = VectorMath.cosineSimilarity(vecA, vecB);
      expect(sim, closeTo(-1.0, 0.0001));
    });
  });

  group('TriggerMatcher 触发词双层匹配测试', () {
    late AppSettings settings;
    late EmbeddingService embeddingService;
    late TriggerMatcher matcher;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        similarityThreshold: 0.80,
      );
      embeddingService = LocalQwenEmbeddingService(settings: settings);
      matcher = TriggerMatcher(settings: settings, embeddingService: embeddingService);
    });

    test('开始词精确匹配', () async {
      final res = await matcher.checkStartWord('晓漫，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
    });

    test('开始词拼音容错匹配（小曼 -> 晓漫）', () async {
      final res = await matcher.checkStartWord('小曼，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
      expect(res.method, equals('pinyin'));
    });

    test('新会话词精确匹配', () async {
      final res = await matcher.checkResetWord('新起一个');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.reset));
    });

    test('结束词精确匹配与剥离', () async {
      final res = await matcher.checkEndWord('今天天气怎么样回答');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.end));

      final stripped = matcher.stripEndWord('今天天气怎么样回答');
      expect(stripped, equals('今天天气怎么样'));
    });

    test('剥离带标点的结束词', () {
      final stripped = matcher.stripEndWord('帮我写一首诗，回答！');
      expect(stripped, equals('帮我写一首诗'));
    });

    test('带句号的结束词剥离（回答。）', () {
      final stripped = matcher.stripEndWord('今天的天气怎么样 回答。');
      expect(stripped, equals('今天的天气怎么样'));
    });

    test('带句号的重置词检测（新起一个。）', () async {
      final res = await matcher.checkResetWord('新起一个。');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.reset));
    });

    test('单句一并包含同音开始词、内容与带句号结束词（小曼 xxx 回答。）', () async {
      final oneShot = await matcher.extractOneShotCommand('小曼 帮我写一首诗 回答。');
      expect(oneShot, isNotNull);
      expect(oneShot!.promptContent, equals('帮我写一首诗'));
      expect(oneShot.startWord, equals('小曼'));
    });

    test('极速粗筛过滤无关环境语音与保留启动词', () {
      expect(matcher.quickWakePlausibilityCheck('今天天气怎么样'), isFalse);
      expect(matcher.quickWakePlausibilityCheck('请帮我倒一杯水'), isFalse);
      expect(matcher.quickWakePlausibilityCheck('这个代码怎么跑起来'), isFalse);

      expect(matcher.quickWakePlausibilityCheck('小曼，今天几号'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('晓漫，帮我查一下'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('小忙'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('小麦'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('新起一个'), isTrue);
    });

    test('近音词“小麦”模糊匹配为“小曼/晓漫”唤醒词', () async {
      final res = await matcher.checkStartWord('小麦，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
    });

    test('单句包含“小麦”与“回答。”单次提问（小麦 xxx 回答。）', () async {
      final oneShot = await matcher.extractOneShotCommand('小麦 帮我写一首诗 回答。');
      expect(oneShot, isNotNull);
      expect(oneShot!.promptContent, equals('帮我写一首诗'));
      expect(oneShot.startWord, equals('小麦'));
    });

    test('轻量前后鼻音拼音模糊匹配（小忙 -> 晓漫）', () async {
      final res = await matcher.checkStartWord('小忙，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
      expect(res.method, equals('fuzzy_pinyin_nasal'));
    });

    test('轻量编辑距离拼音模糊匹配（小南 -> 晓漫）', () async {
      final res = await matcher.checkStartWord('小南，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
      expect(res.method, equals('fuzzy_pinyin_edit_dist'));
    });

    test('多原型向量池唤醒匹配（小慢 -> 命中原型池）', () async {
      await matcher.warmUp();
      final res = await matcher.checkStartWord('小慢，今天几号');
      expect(res.isMatched, isTrue);
      expect(res.type, equals(TriggerType.start));
    });
  });
}
