import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';

/// 1. 新起会话词也要有模糊语义匹配（同音/近义说法都能命中）
/// 2. 开始词 / 结束词 / 新起会话词都支持用分号配置多个
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );

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

  group('多词配置解析', () {
    test('中英文分号与逗号都能分隔，去空去重保序', () {
      expect(
        AppSettings.splitTriggerWords('晓漫；小助手;小秘，小助手'),
        ['晓漫', '小助手', '小秘'],
      );
      expect(AppSettings.splitTriggerWords('  ; ； , '), isEmpty);
      expect(AppSettings.splitTriggerWords('回答'), ['回答']);
    });

    test('AppSettings 暴露 startWords / endWords / resetWords / exitContinuousWords', () {
      settings.startWord = '晓漫；小助手';
      settings.endWord = '回答;完毕';
      settings.resetWord = '新起一个，重新开始';
      settings.exitContinuousWord = '结束对话;退下';
      expect(settings.startWords, ['晓漫', '小助手']);
      expect(settings.endWords, ['回答', '完毕']);
      expect(settings.resetWords, ['新起一个', '重新开始']);
      expect(settings.exitContinuousWords, ['结束对话', '退下']);
    });
  });

  group('多词匹配（分号分隔）', () {
    test('开始词：配置多个后，第二个词也能精确命中', () async {
      settings.startWord = '晓漫；小助手';
      final result = await matcher.checkStartWord('小助手 今天天气怎么样');
      expect(result.isMatched, isTrue);
      expect(result.type, TriggerType.start);
    });

    test('结束词：配置多个后，第二个词也能在句尾命中', () async {
      settings.endWord = '回答；完毕';
      final result = await matcher.checkEndWord('帮我查一下明天的日程完毕');
      expect(result.isMatched, isTrue);
      expect(result.type, TriggerType.end);
    });

    test('结束词：stripEndWord 支持任意一个配置词', () {
      settings.endWord = '回答；完毕';
      expect(matcher.stripEndWord('帮我查一下明天的日程完毕'), '帮我查一下明天的日程');
      expect(matcher.stripEndWord('帮我查一下明天的日程回答'), '帮我查一下明天的日程');
    });

    test('新起会话词：配置多个后，第二个词也能命中', () async {
      settings.resetWord = '新起一个；重新开始';
      final result = await matcher.checkResetWord('重新开始');
      expect(result.isMatched, isTrue);
      expect(result.type, TriggerType.reset);
    });

    test('待机初筛：任一配置词出现就放行', () {
      settings.startWord = '晓漫；小助手';
      settings.resetWord = '新起一个；换个话题';
      expect(matcher.quickWakePlausibilityCheck('小助手在吗'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('换个话题吧'), isTrue);
      expect(matcher.quickWakePlausibilityCheck('今天中午吃什么'), isFalse);
    });
  });

  group('新起会话词的模糊语义匹配', () {
    test('内置同义/同音簇：这些说法都能命中重置', () async {
      const candidates = [
        '新起一个',
        '新启一个',
        '新建会话',
        '重新开始',
        '起个新的',
        '换个话题',
        '新开一个',
      ];
      for (final text in candidates) {
        final result = await matcher.checkResetWord(text);
        expect(
          result.isMatched,
          isTrue,
          reason: '“$text” 应该被识别为新起会话指令',
        );
        expect(result.type, TriggerType.reset);
      }
    });

    test('带标点/尾随语气词也能命中', () async {
      expect((await matcher.checkResetWord('新起一个。')).isMatched, isTrue);
      expect((await matcher.checkResetWord('重新开始吧')).isMatched, isTrue);
    });

    test('句中出现的重置词也能命中（不像结束词那样要求句尾）', () async {
      final result = await matcher.checkResetWord('新起一个，我们聊点别的');
      expect(result.isMatched, isTrue);
      expect(result.startIndex, 0);
    });

    test('普通闲聊不会被误判成重置', () async {
      for (final text in ['今天天气不错', '帮我查一下日程', '这个代码怎么跑起来']) {
        final result = await matcher.checkResetWord(text);
        expect(
          result.isMatched,
          isFalse,
          reason: '“$text” 不应触发新起会话',
        );
      }
    });

    test('长句中间的“重新开始”不触发重置（避免误清上下文）', () async {
      final result =
          await matcher.checkResetWord('我们重新开始这个话题吧不然跑不通');
      expect(result.isMatched, isFalse);
    });

    test('自定义新起会话词也会生成同义簇', () {
      settings.resetWord = '重开一局';
      final variants = matcher.generateResetWordVariants('重开一局');
      expect(variants, contains('重开一局'));
    });
  });

  group('退出连续对话词配置与匹配测试', () {
    test('默认配置解析为“结束对话”与“退下”', () {
      final s = AppSettings();
      expect(s.exitContinuousWord, '结束对话;退下');
      expect(s.exitContinuousWords, ['结束对话', '退下']);
    });

    test('精确匹配配置中的各个退出口令', () async {
      settings.exitContinuousWord = '结束对话;退下';
      expect(await matcher.checkExitContinuousWord('结束对话'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下吧'), isTrue);
      expect(await matcher.checkExitContinuousWord('停止对话'), isTrue);
    });

    test('剥离开始词和结束词后匹配“退下”', () async {
      settings.exitContinuousWord = '结束对话;退下';
      expect(await matcher.checkExitContinuousWord('晓漫退下'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('晓漫退下回答'), isTrue);
    });

    test('支持自定义退出连续对话口令', () async {
      settings.exitContinuousWord = '安息吧;告退';
      expect(await matcher.checkExitContinuousWord('告退'), isTrue);
      expect(await matcher.checkExitContinuousWord('安息吧'), isTrue);
      expect(await matcher.checkExitContinuousWord('晓漫告退回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('结束对话'), isFalse);
    });
  });
}
