import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/trigger_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (methodCall) async => 1,
  );
  HttpOverrides.global = null;

  group('1. AppSettings - 开始词三选项与超时配置测试', () {
    test('默认配置：自动模式，连续对话超时默认 10 分钟', () {
      final settings = AppSettings();
      expect(settings.startWordMode, equals(AppConstants.startWordModeAuto));
      expect(settings.continuousModeTimeoutMinutes, equals(10));
      expect(settings.enableStartWordDetection, isTrue);
      expect(settings.exitContinuousWord, equals('结束对话;退下'));
      expect(settings.exitContinuousWords, equals(['结束对话', '退下']));
    });

    test('显式配置启用模式与关闭模式', () {
      final enabledSettings = AppSettings(
        startWordMode: AppConstants.startWordModeEnabled,
      );
      expect(
          enabledSettings.startWordMode, equals(AppConstants.startWordModeEnabled));
      expect(enabledSettings.enableStartWordDetection, isTrue);

      final disabledSettings = AppSettings(
        startWordMode: AppConstants.startWordModeDisabled,
      );
      expect(disabledSettings.startWordMode,
          equals(AppConstants.startWordModeDisabled));
      expect(disabledSettings.enableStartWordDetection, isFalse);
    });

    test('兼容旧版 enableStartWordDetection 布尔参数', () {
      final legacyFalse = AppSettings(enableStartWordDetection: false);
      expect(
          legacyFalse.startWordMode, equals(AppConstants.startWordModeDisabled));
      expect(legacyFalse.enableStartWordDetection, isFalse);

      final legacyTrue = AppSettings(enableStartWordDetection: true);
      expect(
          legacyTrue.startWordMode, equals(AppConstants.startWordModeEnabled));
      expect(legacyTrue.enableStartWordDetection, isTrue);
    });

    test('序列化与反序列化测试 (toMap & fromMap)', () {
      final s = AppSettings(
        startWordMode: AppConstants.startWordModeAuto,
        continuousModeTimeoutMinutes: 15,
        exitContinuousWord: '退下;退朝',
      );
      final map = s.toMap();
      expect(map['startWordMode'], equals(AppConstants.startWordModeAuto));
      expect(map['continuousModeTimeoutMinutes'], equals(15));
      expect(map['enableStartWordDetection'], isTrue);
      expect(map['exitContinuousWord'], equals('退下;退朝'));

      final restored = AppSettings.fromMap(map);
      expect(restored.startWordMode, equals(AppConstants.startWordModeAuto));
      expect(restored.continuousModeTimeoutMinutes, equals(15));
      expect(restored.enableStartWordDetection, isTrue);
      expect(restored.exitContinuousWord, equals('退下;退朝'));
      expect(restored.exitContinuousWords, equals(['退下', '退朝']));
    });

    test('旧版 Map 反序列化兼容测试', () {
      final oldMapFalse = {'enableStartWordDetection': false};
      final restoredFalse = AppSettings.fromMap(oldMapFalse);
      expect(restoredFalse.startWordMode,
          equals(AppConstants.startWordModeDisabled));
      expect(restoredFalse.enableStartWordDetection, isFalse);
      expect(restoredFalse.exitContinuousWord, equals('结束对话;退下'));

      final oldMapTrue = {'enableStartWordDetection': true};
      final restoredTrue = AppSettings.fromMap(oldMapTrue);
      expect(
          restoredTrue.startWordMode, equals(AppConstants.defaultStartWordMode));
      expect(restoredTrue.enableStartWordDetection, isTrue);
      expect(restoredTrue.exitContinuousWord, equals('结束对话;退下'));
    });
  });

  group('2. TriggerMatcher - 退出连续对话口令识别测试', () {
    late AppSettings settings;
    late TriggerMatcher matcher;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
      );
      matcher = TriggerMatcher(settings: settings);
    });

    test('精确匹配“结束对话”、“退下”和“停止对话”', () async {
      expect(await matcher.checkExitContinuousWord('结束对话'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下吧'), isTrue);
      expect(await matcher.checkExitContinuousWord('停止对话'), isTrue);
    });

    test('带标点符号的口令匹配（如“结束对话。”、“退下！”）', () async {
      expect(await matcher.checkExitContinuousWord('结束对话。'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下！'), isTrue);
      expect(await matcher.checkExitContinuousWord('停止对话！'), isTrue);
    });

    test('剥离开始词后的匹配（如“晓漫结束对话”、“晓漫退下”、“小曼停止对话”）', () async {
      expect(await matcher.checkExitContinuousWord('晓漫结束对话'), isTrue);
      expect(await matcher.checkExitContinuousWord('晓漫退下'), isTrue);
      expect(await matcher.checkExitContinuousWord('小曼停止对话'), isTrue);
    });

    test('剥离结束词后的匹配（如“结束对话回答”、“退下回答”）', () async {
      expect(await matcher.checkExitContinuousWord('结束对话回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('退下回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('停止对话回答'), isTrue);
    });

    test('同时包含开始词与结束词的匹配（如“晓漫退下回答”）', () async {
      expect(await matcher.checkExitContinuousWord('晓漫结束对话回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('晓漫退下回答'), isTrue);
    });

    test('支持自定义退出连续对话口令', () async {
      settings.exitContinuousWord = '告辞;休眠';
      expect(await matcher.checkExitContinuousWord('告辞'), isTrue);
      expect(await matcher.checkExitContinuousWord('休眠'), isTrue);
      expect(await matcher.checkExitContinuousWord('晓漫告辞回答'), isTrue);
      expect(await matcher.checkExitContinuousWord('结束对话'), isFalse);
    });

    test('普通提问不应被误判为退出口令', () async {
      expect(await matcher.checkExitContinuousWord('今天天气怎么样回答'), isFalse);
      expect(await matcher.checkExitContinuousWord('请问怎么结束对话比较礼貌'), isFalse);
      expect(await matcher.checkExitContinuousWord('什么时候停止对话模型会有提示'), isFalse);
    });
  });
}
