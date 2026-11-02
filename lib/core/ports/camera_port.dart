import '../models/app_settings.dart';
import '../models/camera_capture_result.dart';

/// 视觉抓拍与多模态相机服务端口 (Camera Port)
///
/// 定义场景拍照、相机状态监测与设备配置契约。
abstract interface class CameraPort {
  bool get isCameraOpen;
  Future<CameraCaptureResult> capturePhoto();
  void applyConfig(VisionConfig config);
  void dispose();

  // Nano 伴侣相机扩展状态（默认实现，便于非 Nano 适配器）
  bool get isNanoConnected => false;
  bool get isNanoConnecting => false;
  int get nanoBatteryPercent => -1;
  bool get isNanoCharging => false;
  bool get isNanoCapturing => false;

  void setNanoStateListeners({
    void Function(int batteryPercent, bool isCharging)? onBatteryUpdate,
    void Function(bool isCapturing)? onCaptureStateChanged,
  }) {}

  Future<void> toggleNanoConnection(AppSettings settings) async {}
}

/// 相机服务工厂注册表 (Camera Port SPI Registry)
class CameraPortRegistry {
  static CameraPort Function(AppSettings settings)? defaultFactory;
}

