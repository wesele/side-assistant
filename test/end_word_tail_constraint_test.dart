import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/embedding_service.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';

/// 故意抛错：让 TriggerMatcher 跳过远程/本地向量路径，
/// 只测试字面 + 拼音 + 句尾约束，保证测试离线、确定性。
class _NoEmbedding implements EmbeddingService {
  @override
  Future<List<double>> getEmbedding(String text) async {
    throw UnimplementedError('embedding disabled in this test');
  }
}

TriggerMatcher _matcher({String startWord = '晓漫'}) {
  final settings = AppSettings(
    startWord: startWord,
    endWord: '回答',
    resetWord: '新起一个',
    similarityThreshold: 0.80,
  );
  return TriggerMatcher(settings: settings, embeddingService: _NoEmbedding());
}

void main() {
  group('结束词句尾约束', () {
    test('句尾命中', () async {
      final res = await _matcher().checkEndWord('今天天气怎么样回答');
      expect(res.isMatched, isTrue);
      expect(res.startIndex, greaterThanOrEqualTo(0));
    });

    test('句尾带 1 个语气词仍命中', () async {
      expect((await _matcher().checkEndWord('今天天气怎么样回答啊')).isMatched, isTrue);
    });

    test('句尾带 3 个尾随杂音仍命中（ASR 幻听容错）', () async {
      expect((await _matcher().checkEndWord('今天天气怎么样回答一起消')).isMatched, isTrue);
    });

    test('句中“回答一下这个问题”不命中', () async {
      final res = await _matcher().checkEndWord('帮我回答一下这个问题');
      expect(res.isMatched, isFalse);
    });

    test('句首“回答”后面还有大段内容不命中', () async {
      final res = await _matcher().checkEndWord('回答一起消今天天气');
      expect(res.isMatched, isFalse);
    });

    test('“解答一下我的疑惑”不命中', () async {
      final res = await _matcher().checkEndWord('帮我解答一下我的疑惑');
      expect(res.isMatched, isFalse);
    });

    test('“请解答”在句尾命中', () async {
      final res = await _matcher().checkEndWord('今天几号请解答');
      expect(res.isMatched, isTrue);
      expect(res.matchedText, '请解答');
    });
  });

  group('单句一次性指令', () {
    test('开始词 + 内容 + 句尾结束词', () async {
      final oneShot = await _matcher().extractOneShotCommand('小曼 今天天气怎么样 回答');
      expect(oneShot, isNotNull);
      expect(oneShot!.promptContent, '今天天气怎么样');
    });

    test('结束词在句中时不算一次性指令', () async {
      final oneShot = await _matcher().extractOneShotCommand('小曼 帮我回答一下这个问题');
      expect(oneShot, isNull);
    });
  });

  group('自定义唤醒词粗筛', () {
    test('自定义开始词可用', () {
      final matcher = _matcher(startWord: '小助手');
      expect(matcher.quickWakePlausibilityCheck('小助手'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('小助手今天天气'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('今天天气怎么样'), isFalse);
    });

    test('默认开始词仍保留同音容错', () {
      final matcher = _matcher();
      expect(matcher.quickWakePlausibilityCheck('晓漫'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('小曼'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('小麦'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('这个代码怎么跑起来'), isFalse);
    });
  });
}
