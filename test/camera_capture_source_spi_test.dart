import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/vision/camera_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Camera Capture Source SPI & Strategy Tests', () {
    test('1. CameraSourceRegistry 策略注册、获取与状态查询', () {
      final registry = CameraSourceRegistry();
      final mockSource = MockCameraCaptureSource();

      expect(registry.hasSource(CameraSourceType.mock), isFalse);
      expect(registry.getSource(CameraSourceType.mock), isNull);

      registry.register(mockSource);

      expect(registry.hasSource(CameraSourceType.mock), isTrue);
      expect(identical(registry.getSource(CameraSourceType.mock), mockSource), isTrue);
      expect(registry.availableSources.length, equals(1));
      expect(registry.registeredSources.length, equals(1));
    });

    test('2. MockCameraCaptureSource SPI 生命周期契约实现', () async {
      final mock = MockCameraCaptureSource();

      expect(mock.type, equals(CameraSourceType.mock));
      expect(mock.isAvailable, isTrue);
      expect(mock.isOpen, isFalse);

      final opened = await mock.ensureOpen();
      expect(opened, isTrue);
      expect(mock.isOpen, isTrue);

      await mock.close();
      expect(mock.isOpen, isFalse);

      await mock.dispose();
      expect(mock.isOpen, isFalse);
    });

    test('3. Mock 抓拍单帧照片生成符合 RFC 规范的合法 JPEG 图像', () async {
      final mock = MockCameraCaptureSource();
      final result = await mock.captureFrame();

      expect(result.sourceType, equals(CameraSourceType.mock));
      expect(result.isSimulated, isTrue);
      expect(result.imageBytes.isNotEmpty, isTrue);

      // 验证 JPEG 幻数: 0xFF, 0xD8 (SOI - Start of Image) 与 0xFF, 0xD9 (EOI - End of Image)
      final bytes = result.imageBytes;
      expect(bytes[0], equals(0xFF));
      expect(bytes[1], equals(0xD8));
      expect(bytes[bytes.length - 2], equals(0xFF));
      expect(bytes[bytes.length - 1], equals(0xD9));

      // 验证向下兼容的 capturePhoto()
      final photoResult = await mock.capturePhoto();
      expect(photoResult.imageBytes.isNotEmpty, isTrue);
    });

    test('4. 视频预览流 CameraFrame 数据帧发布与订阅', () async {
      final mock = MockCameraCaptureSource();
      final stream = mock.previewStream;
      expect(stream, isNotNull);

      final receivedFrames = <CameraFrame>[];
      final subscription = stream!.listen((frame) {
        receivedFrames.add(frame);
      });

      final testFrame = CameraFrame(
        bytes: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
        width: 1280,
        height: 720,
        format: 'jpeg',
        timestamp: DateTime.now(),
      );

      mock.emitPreviewFrame(testFrame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(receivedFrames.length, equals(1));
      expect(receivedFrames.first.width, equals(1280));
      expect(receivedFrames.first.height, equals(720));
      expect(receivedFrames.first.bytes, testFrame.bytes);

      await subscription.cancel();
      await mock.dispose();
    });

    test('5. CameraService 策略选择与 switchSource 动态源切换', () async {
      final settings = AppSettings(captureSource: AppConstants.captureSourceLocal);
      final cameraService = CameraService(settings: settings);

      expect(cameraService.currentSourceType, equals(CameraSourceType.localDevice));
      expect(cameraService.activeSource, isA<LocalCameraSource>());

      // 切换为 Nano
      await cameraService.switchSource(CameraSourceType.nanoWifi);
      expect(cameraService.settings.captureSource, equals(AppConstants.captureSourceNano));
      expect(cameraService.currentSourceType, equals(CameraSourceType.nanoWifi));
      expect(cameraService.activeSource, isA<NanoCameraSource>());

      // 切换回 Local
      await cameraService.switchSource(CameraSourceType.localDevice);
      expect(cameraService.settings.captureSource, equals(AppConstants.captureSourceLocal));
      expect(cameraService.currentSourceType, equals(CameraSourceType.localDevice));

      // 切换字符串形式
      await cameraService.switchSource(AppConstants.captureSourceNano);
      expect(cameraService.settings.captureSource, equals(AppConstants.captureSourceNano));
      expect(cameraService.currentSourceType, equals(CameraSourceType.nanoWifi));

      cameraService.dispose();
    });

    test('6. CameraService 直接抓拍 takePictureDirect 与流媒体/保活控制', () async {
      final settings = AppSettings(
        captureSource: AppConstants.captureSourceLocal,
        cameraKeepAliveMinutes: 3,
      );
      final cameraService = CameraService(settings: settings);

      expect(cameraService.isStreaming, isFalse);

      // 直接单帧抓拍
      final result = await cameraService.takePictureDirect();
      expect(result.imageBytes.isNotEmpty, isTrue);

      // keepAlive 显式刷新
      cameraService.keepAlive(7);
      expect(cameraService.settings.cameraKeepAliveMinutes, equals(7));
      expect(cameraService.isIdleTimerRunning, isTrue);

      // 流媒体状态管理
      expect(cameraService.isStreaming, isFalse);
      await cameraService.stopStreaming();
      expect(cameraService.isStreaming, isFalse);

      cameraService.dispose();
    });

    test('7. CameraSourceRegistry 卸载与 disposeAll 级联清理', () async {
      final registry = CameraSourceRegistry();
      final mockA = MockCameraCaptureSource();
      final mockB = MockCameraCaptureSource();

      registry.register(mockA);
      expect(registry.hasSource(CameraSourceType.mock), isTrue);

      // unregister
      registry.unregister(CameraSourceType.mock);
      expect(registry.hasSource(CameraSourceType.mock), isFalse);

      registry.register(mockB);
      expect(registry.hasSource(CameraSourceType.mock), isTrue);

      // disposeAll
      await registry.disposeAll();
      expect(registry.registeredSources.isEmpty, isTrue);
    });
  });
}
