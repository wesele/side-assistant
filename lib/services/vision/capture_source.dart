import 'dart:async';
import 'dart:io';
import '../../core/models/app_settings.dart';
import '../../core/platform/camera_plugin_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import '../linux/linux_hardware_service.dart';
import 'android_camera_bridge.dart';

class CameraCaptureResult {
  final Uint8List imageBytes;
  final String filePath;
  final bool isSimulated;

  const CameraCaptureResult({
    required this.imageBytes,
    required this.filePath,
    this.isSimulated = false,
  });
}

/// 统一的拍照源抽象接口
abstract class CaptureSource {
  bool get isOpen;
  Future<bool> ensureOpen();
  Future<CameraCaptureResult> capturePhoto();
  Future<void> close();
  void dispose();
}

/// 本地物理摄像头或离线模拟兜底实现
class LocalCameraSource implements CaptureSource {
  AppSettings settings;
  CameraController? _controller;
  bool _isInitializing = false;
  CameraDescription? _currentSelectedCamera;

  /// Android 走原生 CameraX（后台可用），Linux 走 V4L2/ffmpeg，其他平台继续用 camera 插件。
  final bool _useNativeAndroid = Platform.isAndroid;
  bool get _useLinuxV4l2 => Platform.isLinux && !isRunningInFlutterTest;
  bool _androidOpen = false;
  bool _linuxOpen = false;

  /// 记录当前 Android 会话绑定时使用的配置，配置变更后需要重新绑定。
  String? _openedLensDirection;
  int _openedResolutionWidth = 0;
  int _openedResolutionHeight = 0;

  LocalCameraSource({required this.settings});

  @override
  bool get isOpen => _useNativeAndroid
      ? _androidOpen
      : _useLinuxV4l2
          ? _linuxOpen
          : (_controller != null && _controller!.value.isInitialized);
  CameraController? get controller => _controller;
  CameraDescription? get currentSelectedCamera => _currentSelectedCamera;

  bool _hasNativeConfigChanged() =>
      _openedLensDirection != settings.cameraLensDirection ||
      _openedResolutionWidth != settings.cameraResolutionWidth ||
      _openedResolutionHeight != settings.cameraResolutionHeight;

  Future<CameraDescription?> _findTargetCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return null;

      final targetDirection = settings.cameraLensDirection.toLowerCase() == 'front'
          ? CameraLensDirection.front
          : CameraLensDirection.back;

      for (final cam in cameras) {
        if (cam.lensDirection == targetDirection) {
          return cam;
        }
      }
      return cameras.first;
    } catch (e) {
      debugPrint('[LocalCameraSource] 检查可用摄像头异常: $e');
      return null;
    }
  }

  @override
  Future<bool> ensureOpen() async {
    if (isOpen) {
      if (_useNativeAndroid && _hasNativeConfigChanged()) {
        // 镜头或分辨率被修改：先释放旧会话，再用新配置重新绑定。
        debugPrint('[LocalCameraSource] 拍照配置已变更，重建 CameraX 会话');
        await close();
      } else {
        return true;
      }
    }

    if (_isInitializing) {
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return isOpen;
    }

    _isInitializing = true;
    try {
      if (_useNativeAndroid) {
        final ok = await AndroidCameraBridge.open(
          lensDirection: settings.cameraLensDirection,
          targetWidth: settings.cameraResolutionWidth,
          targetHeight: settings.cameraResolutionHeight,
        );
        _androidOpen = ok;
        if (ok) {
          _openedLensDirection = settings.cameraLensDirection;
          _openedResolutionWidth = settings.cameraResolutionWidth;
          _openedResolutionHeight = settings.cameraResolutionHeight;
        } else {
          debugPrint('[LocalCameraSource] Android 原生相机打开失败'
              '（请确认已授予相机权限，且前台服务包含 camera 类型）');
        }
        return ok;
      }

      if (_useLinuxV4l2) {
        final cams = await LinuxHardwareService.listCameraDevices();
        _linuxOpen = cams.isNotEmpty ||
            (settings.linuxCameraDevice.isNotEmpty &&
                FileSystemEntity.typeSync(settings.linuxCameraDevice) !=
                    FileSystemEntityType.notFound);
        if (!_linuxOpen) {
          debugPrint('[LocalCameraSource] Linux 未检测到 /dev/video* 摄像头设备');
        }
        return _linuxOpen;
      }

      final cam = await _findTargetCamera();
      if (cam == null) {
        debugPrint('[LocalCameraSource] 未找到任何可用物理摄像头，将使用模拟兜底');
        return false;
      }

      _currentSelectedCamera = cam;
      _controller = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      return true;
    } catch (e) {
      debugPrint('[LocalCameraSource] 摄像头初始化失败: $e');
      await close();
      return false;
    } finally {
      _isInitializing = false;
    }
  }

  @override
  Future<CameraCaptureResult> capturePhoto() async {
    if (_useNativeAndroid) {
      final opened = await ensureOpen();
      if (!opened) {
        // Android 上不再静默回退到 1×1 假图：明确抛错，避免把无效图片发给大模型。
        throw Exception('Android 相机不可用：请确认已授予相机权限，且后台服务包含 camera 类型');
      }
      try {
        final shot = await AndroidCameraBridge.capturePhoto(
          sendShortEdge: settings.cameraSendShortEdge,
        );
        return CameraCaptureResult(
          imageBytes: shot.bytes,
          filePath: shot.path,
          isSimulated: false,
        );
      } catch (e) {
        // 相机可能被其他应用抢占或会话失效，标记为未打开以便下次重新绑定。
        _androidOpen = false;
        debugPrint('[LocalCameraSource] Android 原生拍照失败: $e');
        rethrow;
      }
    }

    if (_useLinuxV4l2) {
      try {
        final (bytes, path) = await LinuxHardwareService.captureV4l2Photo(
          configuredDevice: settings.linuxCameraDevice,
          targetWidth: settings.cameraResolutionWidth,
          targetHeight: settings.cameraResolutionHeight,
          sendShortEdge: settings.cameraSendShortEdge,
        );
        _linuxOpen = true;
        return CameraCaptureResult(
          imageBytes: bytes,
          filePath: path,
          isSimulated: false,
        );
      } catch (e) {
        _linuxOpen = false;
        debugPrint('[LocalCameraSource] Linux V4L2 抓拍失败: $e，将转入模拟兜底');
        return _generateFallbackMockCapture();
      }
    }

    final opened = await ensureOpen();

    if (opened && _controller != null && _controller!.value.isInitialized) {
      try {
        final XFile photo = await _controller!.takePicture();
        final bytes = await photo.readAsBytes();
        return CameraCaptureResult(
          imageBytes: bytes,
          filePath: photo.path,
          isSimulated: false,
        );
      } catch (e) {
        debugPrint('[LocalCameraSource] 拍照截帧失败: $e，将转入兜底');
      }
    }

    return _generateFallbackMockCapture();
  }

  @override
  Future<void> close() async {
    if (_useNativeAndroid) {
      _androidOpen = false;
      _openedLensDirection = null;
      _openedResolutionWidth = 0;
      _openedResolutionHeight = 0;
      await AndroidCameraBridge.close();
      return;
    }

    if (_useLinuxV4l2) {
      _linuxOpen = false;
      return;
    }

    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      try {
        await ctrl.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    close();
  }

  static final Uint8List _minimalJpegBytes = Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
    0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
    0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
    0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
    0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
    0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
    0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
    0x00, 0x7F, 0x00, 0xFF, 0xD9
  ]);

  Future<CameraCaptureResult> _generateFallbackMockCapture() async {
    try {
      final tempDir = await StorageBridge.getAppTemporaryDirectory();
      final file = File('${tempDir.path}/mock_camera_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(_minimalJpegBytes);
      return CameraCaptureResult(
        imageBytes: _minimalJpegBytes,
        filePath: file.path,
        isSimulated: true,
      );
    } catch (_) {
      return CameraCaptureResult(
        imageBytes: _minimalJpegBytes,
        filePath: '',
        isSimulated: true,
      );
    }
  }
}
