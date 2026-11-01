import 'dart:typed_data';

/// 抓拍源设备分类
enum CameraSourceType {
  /// 本地物理摄像头（Android CameraX 或桌面平台摄像头插件）
  localDevice,

  /// DJI Osmo Nano 穿戴相机（BLE 唤醒 + Wi-Fi SoftAP 传输）
  nanoWifi,

  /// Linux 无头环境 V4L2 摄像头 (/dev/video*)
  linuxV4l2,

  /// 网络 IP 摄像头 RTSP / HTTP 流
  rtspStream,

  /// 自动化测试与离线模拟兜底
  mock,
}

/// 预览视频帧数据包装
class CameraFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final String format; // 'jpeg', 'yuv420', 'nv21', etc.
  final DateTime timestamp;

  const CameraFrame({
    required this.bytes,
    required this.width,
    required this.height,
    this.format = 'jpeg',
    required this.timestamp,
  });
}

/// 统一的抓拍结果
class CameraCaptureResult {
  final Uint8List imageBytes;
  final String filePath;
  final bool isSimulated;
  final CameraSourceType sourceType;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;

  CameraCaptureResult({
    required this.imageBytes,
    required this.filePath,
    this.isSimulated = false,
    this.sourceType = CameraSourceType.localDevice,
    DateTime? timestamp,
    this.metadata = const {},
  }) : timestamp = timestamp ?? DateTime.now();
}
