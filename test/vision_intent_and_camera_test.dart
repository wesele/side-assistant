import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/vision/camera_service.dart';
import 'package:side_assistant/services/speech/prompt_sound_service.dart';
import 'package:side_assistant/core/models/chat_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PromptSoundService 机械快门音测试', () {
    test('getShutterWavBytes 生成合法的 RIFF/WAVE 44字节头与双脉冲采样', () {
      final wav = PromptSoundService.getShutterWavBytes();
      expect(wav.length, greaterThan(44));

      // 验证 RIFF 标识符 'RIFF' -> 0x52, 0x49, 0x46, 0x46
      expect(wav[0], 0x52);
      expect(wav[1], 0x49);
      expect(wav[2], 0x46);
      expect(wav[3], 0x46);

      // 验证 'WAVE' -> 0x57, 0x41, 0x56, 0x45
      expect(wav[8], 0x57);
      expect(wav[9], 0x41);
      expect(wav[10], 0x56);
      expect(wav[11], 0x45);

      // 验证采样率 22050
      final sampleRate =
          wav[24] | (wav[25] << 8) | (wav[26] << 16) | (wav[27] << 24);
      expect(sampleRate, equals(22050));
    });
  });

  group('CameraService 相机生命周期与抓拍测试', () {
    test('离线/无摄像头环境无缝兜底抓拍', () async {
      final settings = AppSettings(
        cameraKeepAliveMinutes: 3,
        cameraLensDirection: 'back',
      );
      final cameraService = CameraService(settings: settings);

      final result = await cameraService.capturePhoto();
      expect(result.imageBytes.isNotEmpty, isTrue);
      // 检查 JPEG magic number: 0xFF, 0xD8
      expect(result.imageBytes[0], 0xFF);
      expect(result.imageBytes[1], 0xD8);

      cameraService.dispose();
    });

    test('0分钟设置测试：不启动保活空闲计时器，拍完立即关闭', () async {
      final settingsZero = AppSettings(
        cameraKeepAliveMinutes: 0,
        cameraLensDirection: 'back',
      );
      final cameraServiceZero = CameraService(settings: settingsZero);

      // 测试 _resetIdleTimer 在 0 分钟时不启动任何计时器
      cameraServiceZero.resetIdleTimerForTest();
      expect(cameraServiceZero.isIdleTimerRunning, isFalse);

      // 执行抓拍，确保在 0 分钟模式下正常抓拍且相机已关闭
      final result = await cameraServiceZero.capturePhoto();
      expect(result.imageBytes.isNotEmpty, isTrue);
      expect(cameraServiceZero.isCameraOpen, isFalse);

      cameraServiceZero.dispose();
    });

    test('大于0分钟设置测试：启动空闲保活计时器', () async {
      final settingsAlive = AppSettings(
        cameraKeepAliveMinutes: 5,
        cameraLensDirection: 'back',
      );
      final cameraServiceAlive = CameraService(settings: settingsAlive);

      cameraServiceAlive.resetIdleTimerForTest();
      expect(cameraServiceAlive.isIdleTimerRunning, isTrue);

      await cameraServiceAlive.closeCamera();
      expect(cameraServiceAlive.isIdleTimerRunning, isFalse);
      expect(cameraServiceAlive.isCameraOpen, isFalse);

      cameraServiceAlive.dispose();
    });

    test('AppSettings 序列化与反序列化支持 0 分钟', () {
      final settings = AppSettings(cameraKeepAliveMinutes: 0);
      final map = settings.toMap();
      expect(map['cameraKeepAliveMinutes'], equals(0));

      final restored = AppSettings.fromMap(map);
      expect(restored.cameraKeepAliveMinutes, equals(0));
    });
  });

  group('ChatMessage 图像字段与序列化测试', () {
    test('支持序列化与反序列化 imagePath', () {
      final msg = ChatMessage(
        id: 'msg-001',
        role: 'user',
        content: '这是什么花？',
        timestamp: DateTime.now(),
        imagePath: '/tmp/photo.jpg',
      );

      final map = msg.toMap();
      expect(map['imagePath'], equals('/tmp/photo.jpg'));

      final restored = ChatMessage.fromMap(map);
      expect(restored.imagePath, equals('/tmp/photo.jpg'));
      expect(restored.content, equals('这是什么花？'));

      // 验证历史轮次 toOpenAiMessage 降级为纯文本
      final openAiMsg = msg.toOpenAiMessage();
      expect(openAiMsg['role'], equals('user'));
      expect(openAiMsg['content'], equals('这是什么花？'));
      expect(openAiMsg.containsKey('image_url'), isFalse);
    });
  });
}
