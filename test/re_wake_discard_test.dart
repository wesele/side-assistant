import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );
  HttpOverrides.global = null;

  group('激活后再次听到小曼抛弃前文测试', () {
    late AppSettings settings;
    late AssistantController controller;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        silenceTimeoutSeconds: 12,
      );
      controller = AssistantController(settings: settings);
    });

    test('首次唤醒后录入内容，再次听到小曼应清空之前内容并接收新内容', () async {
      // 1. 首次呼叫唤醒
      await controller.processRecognizedText('小曼 我想问一下关于人工智能的发展');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, contains('我想问一下关于人工智能的发展'));

      // 2. 再次听到“小曼 帮我写一首五言绝句”
      await controller.processRecognizedText('小曼 帮我写一首五言绝句');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      // 必须抛弃前文“我想问一下关于人工智能的发展”
      expect(controller.liveTranscript, isNot(contains('人工智能的发展')));
      expect(controller.liveTranscript, equals('帮我写一首五言绝句'));
    });

    test('首次唤醒后录入内容，单独再说“小曼”应清空之前的草稿文本', () async {
      // 1. 首次呼叫唤醒
      await controller.processRecognizedText('小曼 今天的天气真不错');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, equals('今天的天气真不错'));

      // 2. 单独再说“小曼”
      await controller.processRecognizedText('小曼');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      // 应彻底清空
      expect(controller.liveTranscript, isEmpty);
    });

    test('首次唤醒后录入内容，再次听到“小麦”近音词也应抛弃前文', () async {
      // 1. 首次呼叫
      await controller.processRecognizedText('小曼 查一下明天的火车票');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, equals('查一下明天的火车票'));

      // 2. 再次听到近音词“小麦 帮我定个闹钟”
      await controller.processRecognizedText('小麦 帮我定个闹钟');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, isNot(contains('火车票')));
      expect(controller.liveTranscript, equals('帮我定个闹钟'));
    });
  });
}
