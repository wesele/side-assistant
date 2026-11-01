import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/llm/streaming_json_reply_parser.dart';

void main() {
  group('StreamingJsonReplyParser 流式解析测试', () {
    test('标准流式到达：正常提取意图与流式 reply chunk', () {
      final parser = StreamingJsonReplyParser();
      String? resolvedIntent;
      bool? resolvedShouldReply;
      final emittedChunks = <String>[];

      parser.onIntentResolved = (intent, shouldReply) {
        resolvedIntent = intent;
        resolvedShouldReply = shouldReply;
      };
      parser.onReplyChunk = (chunk) {
        emittedChunks.add(chunk);
      };

      // 模拟逐 token 流式到达
      final tokens = [
        '{\n',
        '  "intent": ',
        '"start_or_continue",\n',
        '  "should_reply": true,\n',
        '  "reply": "你好',
        '！今天',
        '天气不错。"',
        '\n}',
      ];

      for (final t in tokens) {
        parser.feed(t);
      }

      final decision = parser.finish();

      expect(resolvedIntent, equals('start_or_continue'));
      expect(resolvedShouldReply, isTrue);
      expect(emittedChunks.join(''), equals('你好！今天天气不错。'));
      expect(decision.intent, equals('start_or_continue'));
      expect(decision.shouldReply, isTrue);
      expect(decision.reply, equals('你好！今天天气不错。'));
    });

    test('忽略旁白：should_reply 为 false，不发出 reply chunk', () {
      final parser = StreamingJsonReplyParser();
      final emittedChunks = <String>[];

      parser.onReplyChunk = (chunk) {
        emittedChunks.add(chunk);
      };

      final tokens = [
        '{"intent": "ignore", ',
        '"should_reply": false, ',
        '"reply": ""}',
      ];

      for (final t in tokens) {
        parser.feed(t);
      }

      final decision = parser.finish();

      expect(decision.intent, equals('ignore'));
      expect(decision.shouldReply, isFalse);
      expect(decision.isIgnore, isTrue);
      expect(emittedChunks, isEmpty);
      expect(decision.reply, isEmpty);
    });

    test('新起会话与转义字符解析测试', () {
      final parser = StreamingJsonReplyParser();
      final tokens = [
        '{\n"intent": "new_session",\n',
        '"should_reply": true,\n',
        '"reply": "好的，\\n新话题开始：\\"请讲\\"。"\n}',
      ];

      for (final t in tokens) {
        parser.feed(t);
      }

      final decision = parser.finish();

      expect(decision.isNewSession, isTrue);
      expect(decision.shouldReply, isTrue);
      expect(decision.reply, equals('好的，\n新话题开始："请讲"。'));
    });

    test('退出连续对话：exit 意图识别测试', () {
      final parser = StreamingJsonReplyParser();
      final tokens = [
        '{"intent": "exit", "should_reply": true, "reply": "好的，那我先退下了。"}',
      ];

      for (final t in tokens) {
        parser.feed(t);
      }

      final decision = parser.finish();

      expect(decision.isExit, isTrue);
      expect(decision.shouldReply, isTrue);
      expect(decision.reply, equals('好的，那我先退下了。'));
    });

    test('模型未遵循 JSON 格式直接吐露纯文本时优雅兜底', () {
      final parser = StreamingJsonReplyParser();
      final tokens = [
        '北京今天',
        '晴天，气温',
        ' 22 度。',
      ];

      for (final t in tokens) {
        parser.feed(t);
      }

      final decision = parser.finish();

      expect(decision.isStartOrContinue, isTrue);
      expect(decision.shouldReply, isTrue);
      expect(decision.reply, equals('北京今天晴天，气温 22 度。'));
    });
  });
}
