import 'dart:async';

import '../../../core/models/camera_capture_result.dart';
import '../android_camera_bridge.dart';

export '../../../core/models/camera_capture_result.dart';

/// 统一的相机捕获源服务提供者接口 (Camera Capture SPI)
///
/// 定义了跨平台、跨形态视觉捕获设备的统一生命周期与动作契约。
abstract class CameraCaptureSource {
  /// 捕获源类型标识
  CameraSourceType get type;

  /// 当前硬件在当前系统上是否可用或物理存在
  bool get isAvailable;

  /// 当前捕获会话是否处于开启激活状态
  bool get isOpen;

  /// 可选的实时预览视频帧广播流（若当前设备仅支持静态单帧抓拍，返回 null）
  Stream<CameraFrame>? get previewStream;

  /// 初始化捕获源驱动与硬件通道
  Future<void> initialize();

  /// 确保捕获通道已连接且就绪，若未就绪则尝试开启
  Future<bool> ensureOpen();

  /// 抓拍单帧照片，支持可选的分辨率与短边约束
  Future<CameraCaptureResult> captureFrame({CameraResolution? resolution});

  /// 向下兼容既有业务 API 的便捷抓拍调用
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  /// 挂起或释放当前摄像硬件会话（进入待机低功耗模式）
  Future<void> close();

  /// 彻底销毁并释放所有硬件连接与子线程句柄
  Future<void> dispose();
}

/// 向后兼容的别名，确保项目中存量引用 CaptureSource 的地方 100% 编译兼容
typedef CaptureSource = CameraCaptureSource;
