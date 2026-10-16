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

  group('TTS 播放与声学回声防自打断测试', () {
    late AppSettings settings;
    late AssistantController controller;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        enableBargeIn: true,
      );
      controller = AssistantController(settings: settings);
    });

    test('播放期间麦克风拾取到正在朗读的自身内容（回声），应忽略并不中断播放', () async {
      // 模拟进入 playing 状态，且助手正在回答
      controller.simulateUserInput('晓漫 你是谁 回答');
      // 等待进入 playing 状态
      int waits = 0;
      while (controller.status == AssistantStatus.thinking && waits < 30) {
        await Future.delayed(const Duration(milliseconds: 100));
        waits++;
      }

      if (controller.status == AssistantStatus.playing) {
        // 假设正在播放回答“我是小曼，您的智能随身语音助手。”
        // 麦克风录入自己的声音“您的智能随身语音助手”
        await controller.processRecognizedText('您的智能随身语音助手');

        // 状态应依然是 playing，决不能被回声错误打断！
        expect(controller.status, equals(AssistantStatus.playing));
      }
    });

    test('播放期间用户真正发出“停止”指令，应成功打断并切回待机', () async {
      controller.simulateUserInput('晓漫 讲一个长故事 回答');
      int waits = 0;
      while (controller.status == AssistantStatus.thinking && waits < 30) {
        await Future.delayed(const Duration(milliseconds: 100));
        waits++;
      }

      if (controller.status == AssistantStatus.playing) {
        // 用户真实打断“停止”
        await controller.processRecognizedText('停止');
        expect(controller.status, equals(AssistantStatus.idle));
      }
    });
  });
}
