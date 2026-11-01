import 'dart:async';
import 'dart:io';

import '../../../core/models/app_settings.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../../linux/linux_hardware_service.dart';
import 'camera_capture_source.dart';
import 'mock_camera_capture_source.dart';

/// Linux 无头环境 V4L2 摄像头抓拍策略
class LinuxV4L2CaptureSource implements CameraCaptureSource {
  AppSettings settings;
  bool _isOpen = false;

  LinuxV4L2CaptureSource({required this.settings});

  @override
  CameraSourceType get type => CameraSourceType.linuxV4l2;

  @override
  bool get isAvailable {
    if (!Platform.isLinux || isRunningInFlutterTest) return false;
    final dev = settings.linuxCameraDevice;
    if (dev.isNotEmpty &&
        FileSystemEntity.typeSync(dev) != FileSystemEntityType.notFound) {
      return true;
    }
    final v4lDir = Directory('/sys/class/video4linux');
    return v4lDir.existsSync() && v4lDir.listSync().isNotEmpty;
  }

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<CameraFrame>? get previewStream => null;

  @override
  Future<void> initialize() async {
    await ensureOpen();
  }

  @override
  Future<bool> ensureOpen() async {
    if (!Platform.isLinux || isRunningInFlutterTest) {
      _isOpen = false;
      return false;
    }
    try {
      final cams = await LinuxHardwareService.listCameraDevices();
      _isOpen = cams.isNotEmpty ||
          (settings.linuxCameraDevice.isNotEmpty &&
              FileSystemEntity.typeSync(settings.linuxCameraDevice) !=
                  FileSystemEntityType.notFound);
      return _isOpen;
    } catch (_) {
      _isOpen = false;
      return false;
    }
  }

  @override
  Future<CameraCaptureResult> captureFrame({CameraResolution? resolution}) async {
    try {
      final (bytes, path) = await LinuxHardwareService.captureV4l2Photo(
        configuredDevice: settings.linuxCameraDevice,
        targetWidth: resolution?.width ?? settings.cameraResolutionWidth,
        targetHeight: resolution?.height ?? settings.cameraResolutionHeight,
        sendShortEdge: settings.cameraSendShortEdge,
      );
      _isOpen = true;
      return CameraCaptureResult(
        imageBytes: bytes,
        filePath: path,
        isSimulated: false,
        sourceType: CameraSourceType.linuxV4l2,
        metadata: {
          'device': settings.linuxCameraDevice,
          'width': resolution?.width ?? settings.cameraResolutionWidth,
          'height': resolution?.height ?? settings.cameraResolutionHeight,
        },
      );
    } catch (e) {
      _isOpen = false;
      debugPrint('[LinuxV4L2CaptureSource] V4L2 抓拍异常: $e，降级回退至模拟兜底');
      final mock = MockCameraCaptureSource();
      final mockRes = await mock.captureFrame(resolution: resolution);
      return CameraCaptureResult(
        imageBytes: mockRes.imageBytes,
        filePath: mockRes.filePath,
        isSimulated: true,
        sourceType: CameraSourceType.linuxV4l2,
        metadata: {
          'error': e.toString(),
        },
      );
    }
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  Future<void> dispose() async {
    await close();
  }
}
