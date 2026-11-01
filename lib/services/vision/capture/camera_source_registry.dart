import 'dart:async';

import 'camera_capture_source.dart';

/// 相机捕获源注册表 (Camera Source Registry)
///
/// 遵循开闭原则 (OCP)，支持动态插拔不同形态的硬件捕获源（Local、Linux V4L2、DJI Nano、Mock、RTSP 流等）。
class CameraSourceRegistry {
  final Map<CameraSourceType, CameraCaptureSource> _sources = {};

  /// 注册捕获源策略实例
  void register(CameraCaptureSource source) {
    _sources[source.type] = source;
  }

  /// 获取指定类型的捕获源策略实例，未注册时返回 null
  CameraCaptureSource? getSource(CameraSourceType type) => _sources[type];

  /// 检查某类型的捕获源是否已注册
  bool hasSource(CameraSourceType type) => _sources.containsKey(type);

  /// 注销指定类型的捕获源，并触发其销毁回调
  void unregister(CameraSourceType type) {
    final removed = _sources.remove(type);
    removed?.dispose();
  }

  /// 获取所有当前物理或环境可用的捕获源列表
  List<CameraCaptureSource> get availableSources =>
      _sources.values.where((s) => s.isAvailable).toList();

  /// 获取所有已注册的捕获源列表
  List<CameraCaptureSource> get registeredSources =>
      _sources.values.toList();

  /// 释放并清理所有已注册的捕获源策略
  Future<void> disposeAll() async {
    for (final source in _sources.values) {
      await source.dispose();
    }
    _sources.clear();
  }
}
