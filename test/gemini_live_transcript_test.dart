import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/speech/support/gemini_live_transcript_accumulator.dart';

/// 记录累积器回调的测试夹具：完全不涉及 socket，直接喂 JSON 帧。
class _Harness {
  _Harness({this.connectionId = 1}) {
    accumulator = GeminiLiveTranscriptAccumulator(
      activeConnectionId: () => connectionId,
      partialTextCallback: () => _sink,
      onSetupComplete: () => setupCompletes++,
      onServerError: errors.add,
      onGoAway: goAways.add,
      onMessageReceived: () => messages++,
      onFinish: () => finishes++,
    );
  }

  int connectionId;
  late final GeminiLiveTranscriptAccumulator accumulator;

  int setupCompletes = 0;
  final List<String> errors = <String>[];
  final List<Map<dynamic, dynamic>> goAways = <Map<dynamic, dynamic>>[];
  final List<String> partials = <String>[];
  bool enablePartials = true;
  int messages = 0;
  int finishes = 0;

  void Function(String text)? get _sink => enablePartials ? partials.add : null;

  String get text => accumulator.combinedText;

  void feed(Map<String, dynamic> message, {int? from}) {
    accumulator.handleMessage(jsonEncode(message), from ?? connectionId);
  }

  void feedRaw(dynamic raw, {int? from}) {
    accumulator.handleMessage(raw, from ?? connectionId);
  }
}

Map<String, dynamic> _serverContent(Map<String, dynamic> content) => {
      'serverContent': content,
    };

Map<String, dynamic> _interim(String text) => _serverContent({
      'interimInputTranscription': {'text': text}
    });

Map<String, dynamic> _final(String text) => _serverContent({
      'inputTranscription': {'text': text}
    });

void main() {
  group('GeminiLiveTranscriptAccumulator 文本累积', () {
    test('单条 interim 文本累积为当前文本', () {
      final h = _Harness();
      h.feed(_interim('回答'));

      expect(h.text, '回答');
      expect(h.accumulator.interimText, '回答');
      expect(h.accumulator.hasFinalTranscript, isFalse);
      expect(h.partials, isEmpty, reason: '默认不回调中间结果');
    });

    test('同一 turn 内后到的 interim 覆盖前一条而不是拼接', () {
      final h = _Harness();
      h.feed(_interim('今'));
      h.feed(_interim('今天北京'));
      h.feed(_interim('今天北京天气怎么样'));

      expect(h.text, '今天北京天气怎么样');
    });

    test('inputTranscription 覆盖 interim，成为最终文本', () {
      final h = _Harness();
      h.feed(_interim('回答'));
      h.feed(_final('回答。'));

      expect(h.accumulator.currentTurnFinalText, '回答。');
      expect(h.accumulator.interimText, '');
      expect(h.text, '回答。');
      expect(h.accumulator.hasFinalTranscript, isTrue);
    });

    test('空的 inputTranscription 不覆盖已有文本', () {
      final h = _Harness();
      h.feed(_interim('回答'));
      h.feed(_final(''));

      expect(h.text, '回答');
      expect(h.accumulator.hasFinalTranscript, isFalse);
    });

    test('新 interim 到来时归档上一子轮次的最终文本并拼接', () {
      final h = _Harness();
      h.feed(_interim('今天北京天气怎么样'));
      h.feed(_final('今天北京天气怎么样，'));
      // 服务端内部 VAD 切了第二段子轮次：旧的最终文本必须保留在前。
      h.feed(_interim('回答'));

      expect(h.accumulator.completedTurns, ['今天北京天气怎么样，']);
      expect(h.accumulator.currentTurnFinalText, '');
      expect(h.text, '今天北京天气怎么样，回答');
    });

    test('ACTIVITY_START 归档上一子轮次并清空 interim', () {
      final h = _Harness();
      h.feed(_final('帮我查一下'));
      h.feed({
        'voiceActivity': {'type': 'ACTIVITY_START'},
      });

      expect(h.accumulator.completedTurns, ['帮我查一下']);
      expect(h.accumulator.currentTurnFinalText, '');
      expect(h.accumulator.interimText, '');
    });

    test('全外文文本不产出内容（语种过滤语义不变）', () {
      final h = _Harness();
      h.feed(_final('Hello, can you help me book a table for two tonight?'));

      expect(h.text, '');
    });

    test('resetTurn 清空上一段的全部累积', () {
      final h = _Harness();
      h.feed(_final('今天天气'));
      h.feed(_interim('回答'));
      h.accumulator.resetTurn();

      expect(h.text, '');
      expect(h.accumulator.completedTurns, isEmpty);
      expect(h.accumulator.audioEnded, isFalse);
      expect(h.accumulator.generationDone, isFalse);
      expect(h.accumulator.turnCompleteReceived, isFalse);
    });
  });

  group('GeminiLiveTranscriptAccumulator 收尾判定', () {
    test('turnComplete 后触发收尾，最终文本保留', () async {
      final h = _Harness();
      h.accumulator.markAudioEnded();
      h.feed(_interim('回答'));
      h.feed(_final('回答。'));
      h.feed(_serverContent({'turnComplete': true}));

      expect(h.accumulator.turnCompleteReceived, isTrue);
      expect(h.finishes, 1);
      expect(h.text, '回答。');
      h.accumulator.cancelFinishGrace();
    });

    test('未发 audioStreamEnd 时 generationComplete 不提前收尾', () async {
      final h = _Harness();
      h.feed(_final('回答。'));
      h.feed(_serverContent({'generationComplete': true}));

      expect(h.accumulator.generationDone, isTrue);
      expect(h.finishes, 0);
    });

    test('audioStreamEnd 后 generationComplete 且已有最终文本：立即收尾', () async {
      final h = _Harness();
      h.accumulator.markAudioEnded();
      h.feed(_final('回答。'));
      h.feed(_serverContent({'generationComplete': true}));

      expect(h.finishes, 1);
    });

    test('只有 generationComplete 没有最终文本：250ms 宽限后才收尾', () async {
      final h = _Harness();
      h.accumulator.markAudioEnded();
      h.feed(_interim('回答'));
      h.feed(_serverContent({'generationComplete': true}));

      expect(h.finishes, 0, reason: '必须给服务端补发最终转写的时间');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.finishes, 1);
    });

    test('cancelFinishGrace 可以取消宽限收尾', () async {
      final h = _Harness();
      h.accumulator.markAudioEnded();
      h.feed(_interim('回答'));
      h.feed(_serverContent({'generationComplete': true}));
      h.accumulator.cancelFinishGrace();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.finishes, 0);
    });

    test('resetTurn 取消上一段残留的宽限计时', () async {
      final h = _Harness();
      h.accumulator.markAudioEnded();
      h.feed(_interim('回答'));
      h.feed(_serverContent({'generationComplete': true}));
      h.accumulator.resetTurn();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.finishes, 0);
    });
  });

  group('GeminiLiveTranscriptAccumulator 连接代次', () {
    test('旧 connectionId 的迟到消息被整体丢弃', () {
      final h = _Harness(connectionId: 2);
      h.feed(_final('旧连接文本'), from: 1);
      h.feed(_interim('旧连接中间结果'), from: 1);
      h.feed(_serverContent({'turnComplete': true}), from: 1);

      expect(h.text, '');
      expect(h.accumulator.hasFinalTranscript, isFalse);
      expect(h.accumulator.turnCompleteReceived, isFalse);
      expect(h.finishes, 0);
      expect(h.messages, 0, reason: '被丢弃的消息不应重置静默兜底计时');
    });

    test('代次匹配后恢复正常处理', () {
      final h = _Harness(connectionId: 2);
      h.feed(_final('旧连接文本'), from: 1);
      h.feed(_final('新连接文本'), from: 2);

      expect(h.text, '新连接文本');
      expect(h.messages, 1);
    });

    test('markDisposed 后所有消息都被丢弃', () {
      final h = _Harness();
      h.accumulator.markDisposed();
      h.feed(_final('回答'));
      h.feed({'setupComplete': {}});

      expect(h.text, '');
      expect(h.setupCompletes, 0);
      expect(h.messages, 0);
    });
  });

  group('GeminiLiveTranscriptAccumulator 协议健壮性', () {
    test('空帧/非 JSON/非对象 JSON/非法 UTF-8 均不抛异常且被忽略', () {
      final h = _Harness();
      expect(() {
        h.feedRaw('');
        h.feedRaw('   ');
        h.feedRaw('not json');
        h.feedRaw('[1,2,3]');
        h.feedRaw('"just a string"');
        h.feedRaw('123');
        h.feedRaw(null);
        h.feedRaw(42);
        h.feedRaw(<int>[0xff, 0xfe, 0xfd]);
        h.feedRaw(<String, dynamic>{'serverContent': 'oops'});
      }, returnsNormally);

      expect(h.messages, 0);
      expect(h.text, '');
      expect(h.finishes, 0);
    });

    test('二进制帧按 UTF-8 解码后正常处理', () {
      final h = _Harness();
      h.feedRaw(utf8.encode(jsonEncode(_final('回答。'))));

      expect(h.text, '回答。');
      expect(h.messages, 1);
    });

    test('未知字段与残缺 serverContent 不影响已有文本', () {
      final h = _Harness();
      h.feed(_final('回答。'));
      h.feed({
        'unknownField': {'nested': true}
      });
      h.feed(_serverContent({'unknownTranscription': 'x'}));
      h.feed(_serverContent({'interimInputTranscription': 'not a map'}));
      h.feed(_serverContent({
        'inputTranscription': {'text': 42}
      }));

      expect(h.text, '回答。');
      expect(h.finishes, 0);
      expect(h.messages, 5, reason: '合法 JSON 消息都应重置静默兜底计时');
    });

    test('setupComplete / error / goAway 分派到对应回调', () {
      final h = _Harness();
      h.feed({'setupComplete': {}});
      expect(h.setupCompletes, 1);

      h.feed({
        'error': {'message': '模型不可用'},
      });
      expect(h.errors, ['模型不可用']);

      h.feed({'error': 'plain error'});
      expect(h.errors, ['模型不可用', 'plain error']);

      h.feed({
        'goAway': {'timeLeft': '5s'},
      });
      expect(h.goAways, hasLength(1));
      expect(h.messages, 4);
    });
  });

  group('GeminiLiveTranscriptAccumulator 中间结果回调', () {
    test('开启 emitPartial 后 interim 经防抖回调累积文本', () async {
      final h = _Harness();
      h.accumulator.resetTurn(emitPartial: true);
      h.feed(_interim('今天北京'));
      h.feed(_interim('今天北京天气怎么样'));

      expect(h.partials, isEmpty, reason: '40ms 防抖期内不应回调');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.partials, ['今天北京天气怎么样']);
    });

    test('相同文本不会重复回调', () async {
      final h = _Harness();
      h.accumulator.resetTurn(emitPartial: true);
      h.feed(_interim('回答'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      h.feed(_interim('回答'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(h.partials, ['回答']);
    });

    test('待机唤醒语境（wakeContext）不回调中间结果', () async {
      final h = _Harness();
      h.accumulator.resetTurn(emitPartial: true, wakeContext: true);
      h.feed(_interim('晓漫'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(h.partials, isEmpty);
    });

    test('没有注册回调时安全跳过', () async {
      final h = _Harness()..enablePartials = false;
      h.accumulator.resetTurn(emitPartial: true);
      expect(() => h.feed(_interim('回答')), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.partials, isEmpty);
    });

    test('非中文中间结果不回调', () async {
      final h = _Harness();
      h.accumulator.resetTurn(emitPartial: true);
      h.feed(_interim('Hello how are you today'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(h.partials, isEmpty);
    });

    test('endTurn 之后到期的防抖不再回调', () async {
      final h = _Harness();
      h.accumulator.resetTurn(emitPartial: true);
      h.feed(_interim('回答'));
      h.accumulator.endTurn();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(h.partials, isEmpty);
    });
  });

  group('GeminiLiveTranscriptText 文本规则', () {
    test('finalize 清理空格并保留中文结果', () {
      expect(
        GeminiLiveTranscriptText.finalize(
          ' 回答 时间 ',
          wakeContext: false,
          audioSeconds: 1.5,
        ),
        '回答时间',
      );
    });

    test('finalize 丢弃非中文结果', () {
      expect(
        GeminiLiveTranscriptText.finalize(
          'Hello, how are you today?',
          wakeContext: false,
          audioSeconds: 1.5,
        ),
        '',
      );
      expect(
        GeminiLiveTranscriptText.finalize(
          '',
          wakeContext: false,
          audioSeconds: 0,
        ),
        '',
      );
    });

    test('combineSubTurns 优先使用当前最终文本而不是 interim', () {
      expect(
        GeminiLiveTranscriptText.combineSubTurns(
          completedTurns: const ['前半句，'],
          currentTurnFinalText: '最终文本',
          interimText: '中间文本',
        ),
        '前半句，最终文本',
      );
    });
  });
}
