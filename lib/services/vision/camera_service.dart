import 'dart:async';
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/camera_plugin_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import 'capture_source.dart';
import 'nano/nano_camera_source.dart';

export 'capture_source.dart';
export 'nano/nano_camera_source.dart';

/// 摄像头管理服务：管理拍照源路由（本地镜头 / DJI Osmo Nano）、空闲超时自动休眠释放
class CameraService {
  AppSettings settings;
  late final LocalCameraSource _localSource;
  late final NanoCameraSource _nanoSource;

  Timer? _idleCloseTimer;

  CameraService({
    required this.settings,
    LocalCameraSource? localSource,
    NanoCameraSource? nanoSource,
  }) {
    _localSource = localSource ?? LocalCameraSource(settings: settings);
    _nanoSource = nanoSource ?? NanoCameraSource(settings: settings);
  }

  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
    _localSource.settings = newSettings;
    _nanoSource.settings = newSettings;
    if (settings.captureSource == AppConstants.captureSourceNano) {
      _idleCloseTimer?.cancel();
      _idleCloseTimer = null;
    }
  }

  CaptureSource get activeSource =>
      settings.captureSource == AppConstants.captureSourceNano ? _nanoSource : _localSource;

  LocalCameraSource get localSource => _localSource;
  NanoCameraSource get nanoSource => _nanoSource;

  bool get isCameraOpen => activeSource.isOpen;
  CameraController? get controller => _localSource.controller;
  CameraDescription? get currentSelectedCamera => _localSource.currentSelectedCamera;
  bool get isIdleTimerRunning => _idleCloseTimer != null && _idleCloseTimer!.isActive;

  /// 重置空闲超时关闭计时器（每次拍照或触发视觉意图时调用）
  void _resetIdleTimer() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    // Nano 相机模式下保持蓝牙常连，空闲关闭配置无效
    if (settings.captureSource == AppConstants.captureSourceNano) {
      return;
    }
    if (settings.cameraKeepAliveMinutes <= 0) {
      return;
    }
    final minutes = settings.cameraKeepAliveMinutes.clamp(1, 10);
    _idleCloseTimer = Timer(Duration(minutes: minutes), () {
      debugPrint('[CameraService] 拍照源已空闲 $minutes 分钟，自动关闭释放资源以保护隐私与电量');
      closeCamera();
    });
  }

  @visibleForTesting
  void resetIdleTimerForTest() => _resetIdleTimer();

  /// 初始化或复用已开启的拍照源
  Future<bool> ensureCameraOpen() async {
    final ok = await activeSource.ensureOpen();
    if (ok) {
      _resetIdleTimer();
    }
    return ok;
  }

  /// 执行画面抓拍：委托给当前 activeSource 执行
  Future<CameraCaptureResult> capturePhoto() async {
    try {
      final result = await activeSource.capturePhoto();
      return result;
    } finally {
      if (settings.captureSource == AppConstants.captureSourceNano) {
        // Nano 相机模式下保持蓝牙常连，空闲关闭配置无效，无需关闭蓝牙
        debugPrint('[CameraService] Nano 相机模式：保持蓝牙连接，不执行空闲关闭');
      } else if (settings.cameraKeepAliveMinutes <= 0) {
        debugPrint('[CameraService] 拍照源空闲关闭设置为0分钟，拍完立即关闭');
        await closeCamera();
      } else {
        _resetIdleTimer();
      }
    }
  }

  /// 释放并关闭当前拍照源
  Future<void> closeCamera() async {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    await activeSource.close();
  }

  /// 销毁服务
  void dispose() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _localSource.dispose();
    _nanoSource.dispose();
  }
}

