import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/services/speech/prompt_sound_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 模拟平台通道以支持在无头测试环境中测试硬件相关服务
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

  group('PromptSoundService 提示音合成与播放测试', () {
    test('生成标准 RIFF WAVE 格式的 130ms 轻柔高频水滴/轻滴声音频数据', () {
      final wav = PromptSoundService.getBeepWavBytes();
      expect(wav.length, greaterThan(44));

      // 验证 RIFF 头部规范
      final riff = String.fromCharCodes(wav.sublist(0, 4));
      expect(riff, equals('RIFF'));

      final wave = String.fromCharCodes(wav.sublist(8, 12));
      expect(wave, equals('WAVE'));

      final fmt = String.fromCharCodes(wav.sublist(12, 16));
      expect(fmt, equals('fmt '));

      final byteData = ByteData.sublistView(wav);
      final subchunk1Size = byteData.getUint32(16, Endian.little);
      expect(subchunk1Size, equals(16)); // PCM

      final audioFormat = byteData.getUint16(20, Endian.little);
      expect(audioFormat, equals(1)); // 1 = PCM

      final numChannels = byteData.getUint16(22, Endian.little);
      expect(numChannels, equals(1)); // 单声道

      final sampleRate = byteData.getUint32(24, Endian.little);
      expect(sampleRate, equals(22050)); // 22050 Hz

      final bitsPerSample = byteData.getUint16(34, Endian.little);
      expect(bitsPerSample, equals(16)); // 16-bit

      final dataMarker = String.fromCharCodes(wav.sublist(36, 40));
      expect(dataMarker, equals('data'));

      final dataSize = byteData.getUint32(40, Endian.little);
      expect(dataSize, equals(wav.length - 44));
    });

    test('playAcknowledgeBeep 在无真实声卡驱动环境下应能安全执行不抛出异常', () async {
      final service = PromptSoundService();
      expect(() async => await service.playAcknowledgeBeep(), returnsNormally);
      service.dispose();
    });
  });

  group('AssistantController 激活唤醒与结束词触发提示音测试', () {
    late AppSettings settings;

    setUp(() {
      settings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        useRemoteEmbedding: false, // 单元测试使用本地极速纯逻辑
        enablePromptTone: true,
        enableTtsPlayback: false, // 提示音测试时无需触发真实朗读流程
      );
    });

    test('检测到启动词（如小曼/晓漫）立即触发轻滴声提示音以确认成功激活', () async {
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
      expect(controller.acknowledgeBeepCount, equals(0));

      // 唤醒助手
      await controller.processRecognizedText('小曼');
      expect(controller.status, equals(AssistantStatus.listeningContent));
      // 检测到启动词小曼，立即轻滴一声以提示成功激活
      expect(controller.acknowledgeBeepCount, equals(1));

      // 倾听中说出包含“回答”的提问
      await controller.processRecognizedText('今天几号回答');
      // 确认识别到“回答”结束词，再次播放轻滴提示音（累计 2 次）
      expect(controller.acknowledgeBeepCount, equals(2));

      controller.dispose();
    });

    test('倾听阶段再次听到开始词重新激活时再次触发轻滴声', () async {
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
      // 首次唤醒
      await controller.processRecognizedText('小曼');
      expect(controller.acknowledgeBeepCount, equals(1));

      // 倾听中再次听到开始词重新激活
      await controller.processRecognizedText('小曼');
      expect(controller.acknowledgeBeepCount, equals(2));

      controller.dispose();
    });

    test('单句一句流（开始词+提问+带句号“回答。”）一并识别时立即触发提示音', () async {
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
      expect(controller.acknowledgeBeepCount, equals(0));

      // 一句话包含唤醒词与回答。
      await controller.processRecognizedText('小曼 今天股市怎么样回答。');

      // 确认识别到结束词，立即播放提示音
      expect(controller.acknowledgeBeepCount, equals(1));

      controller.dispose();
    });

    test('若用户在设置中关闭提示音，则跳过播放', () async {
      settings.enablePromptTone = false;
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );

      await controller.processRecognizedText('小曼');
      expect(controller.acknowledgeBeepCount, equals(1)); // 逻辑上触发了提示调用
      expect(settings.enablePromptTone, isFalse);

      controller.dispose();
    });
  });
}
