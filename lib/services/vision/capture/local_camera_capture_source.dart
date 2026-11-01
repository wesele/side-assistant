import 'dart:async';
import 'dart:io';

import '../../../core/models/app_settings.dart';
import '../../../core/platform/camera_plugin_bridge.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../android_camera_bridge.dart';
import 'camera_capture_source.dart';
import 'mock_camera_capture_source.dart';

/// 本地物理摄像头策略（支持 Android CameraX 原生通道与桌面平台 CameraController）
class LocalCameraCaptureSource implements CameraCaptureSource {
  AppSettings settings;
  CameraController? _controller;
  bool _isInitializing = false;
  CameraDescription? _currentSelectedCamera;

  final bool _useNativeAndroid = Platform.isAndroid;
  bool _androidOpen = false;

  String? _openedLensDirection;
  int _openedResolutionWidth = 0;
  int _openedResolutionHeight = 0;

  LocalCameraCaptureSource({required this.settings});

  @override
  CameraSourceType get type => CameraSourceType.localDevice;

  @override
  bool get isAvailable {
    if (_useNativeAndroid) return true;
    if (Platform.isLinux && !isRunningInFlutterTest) return false;
    return true;
  }

  @override
  bool get isOpen => _useNativeAndroid
      ? _androidOpen
      : (_controller != null && _controller!.value.isInitialized);

  CameraController? get controller => _controller;
  CameraDescription? get currentSelectedCamera => _currentSelectedCamera;

  @override
  Stream<CameraFrame>? get previewStream => null;

  bool _hasNativeConfigChanged() =>
      _openedLensDirection != settings.cameraLensDirection ||
      _openedResolutionWidth != settings.cameraResolutionWidth ||
      _openedResolutionHeight != settings.cameraResolutionHeight;

  Future<CameraDescription?> _findTargetCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return null;

      final targetDirection =
          settings.cameraLensDirection.toLowerCase() == 'front'
              ? CameraLensDirection.front
              : CameraLensDirection.back;

      for (final cam in cameras) {
        if (cam.lensDirection == targetDirection) {
          return cam;
        }
      }
      return cameras.first;
    } catch (e) {
      debugPrint('[LocalCameraCaptureSource] 检查可用摄像头异常: $e');
      return null;
    }
  }

  @override
  Future<void> initialize() async {
    await ensureOpen();
  }

  @override
  Future<bool> ensureOpen() async {
    if (isOpen) {
      if (_useNativeAndroid && _hasNativeConfigChanged()) {
        debugPrint('[LocalCameraCaptureSource] 拍照配置已变更，重建 CameraX 会话');
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
          debugPrint('[LocalCameraCaptureSource] Android 原生相机打开失败'
              '（请确认已授予相机权限，且前台服务包含 camera 类型）');
        }
        return ok;
      }

      final cam = await _findTargetCamera();
      if (cam == null) {
        debugPrint('[LocalCameraCaptureSource] 未找到任何可用物理摄像头，将使用模拟兜底');
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
      debugPrint('[LocalCameraCaptureSource] 摄像头初始化失败: $e');
      await close();
      return false;
    } finally {
      _isInitializing = false;
    }
  }

  @override
  Future<CameraCaptureResult> captureFrame({CameraResolution? resolution}) async {
    if (_useNativeAndroid) {
      final opened = await ensureOpen();
      if (!opened) {
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
          sourceType: CameraSourceType.localDevice,
        );
      } catch (e) {
        _androidOpen = false;
        debugPrint('[LocalCameraCaptureSource] Android 原生拍照失败: $e');
        rethrow;
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
          sourceType: CameraSourceType.localDevice,
        );
      } catch (e) {
        debugPrint('[LocalCameraCaptureSource] 拍照截帧失败: $e，将转入兜底');
      }
    }

    final mock = MockCameraCaptureSource();
    final mockRes = await mock.captureFrame(resolution: resolution);
    return CameraCaptureResult(
      imageBytes: mockRes.imageBytes,
      filePath: mockRes.filePath,
      isSimulated: true,
      sourceType: CameraSourceType.localDevice,
    );
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

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

    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      try {
        await ctrl.dispose();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    await close();
  }
}

/// 向后兼容类型别名
typedef LocalCameraSource = LocalCameraCaptureSource;
