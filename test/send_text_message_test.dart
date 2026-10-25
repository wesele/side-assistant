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

  group('sendTextMessage 直接输入文本发送测试', () {
    late AppSettings settings;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        useRemoteEmbedding: false,
        enableTtsPlayback: false,
      );
    });

    test('直接输入文本发送不应检测或要求开始词和结束词', () async {
      final controller = AssistantController(settings: settings);

      // 处于待机状态（idle）
      expect(controller.status, equals(AssistantStatus.idle));

      // 直接发送一段普通文本（不含任何开始词“晓漫”和结束词“回答”）
      const query = '今天天气怎么样？';
      await controller.sendTextMessage(query);

      // 验证已直接生成用户消息，文本完全一致，未被置灰或忽略
      final userMsgs = controller.messages.where((m) => m.role == 'user').toList();
      expect(userMsgs, isNotEmpty);
      expect(userMsgs.last.content, equals(query));

      controller.dispose();
    });

    test('文本中包含结束词（如“回答”）时，不得作为结束词剥离，必须完整保留', () async {
      final controller = AssistantController(settings: settings);

      const queryWithEndWord = '请帮我回答这个问题，不要沉默';
      await controller.sendTextMessage(queryWithEndWord);

      final userMsgs = controller.messages.where((m) => m.role == 'user').toList();
      expect(userMsgs, isNotEmpty);
      expect(userMsgs.last.content, equals(queryWithEndWord));

      controller.dispose();
    });

    test('文本中包含开始词（如“晓漫”）时，不得作为唤醒词截断，必须完整保留', () async {
      final controller = AssistantController(settings: settings);

      const queryWithStartWord = '晓漫这个名字背后的寓意是什么？';
      await controller.sendTextMessage(queryWithStartWord);

      final userMsgs = controller.messages.where((m) => m.role == 'user').toList();
      expect(userMsgs, isNotEmpty);
      expect(userMsgs.last.content, equals(queryWithStartWord));

      controller.dispose();
    });

    test('发送空白文本应直接忽略', () async {
      final controller = AssistantController(settings: settings);

      await controller.sendTextMessage('   ');
      expect(controller.messages, isEmpty);

      controller.dispose();
    });

    test('直接输入“新起一个”依然支持快速重置会话', () async {
      final controller = AssistantController(settings: settings);

      // 先发一条消息
      await controller.sendTextMessage('你好');
      expect(controller.messages, isNotEmpty);
      final prevSessionId = controller.currentSessionId;

      // 发送“新起一个”
      await controller.sendTextMessage('新起一个');
      expect(controller.messages, isEmpty);
      expect(controller.currentSessionId, isNot(equals(prevSessionId)));

      controller.dispose();
    });
  });
}
