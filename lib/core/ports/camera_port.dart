import '../models/camera_capture_result.dart';
import '../models/domain_configs.dart';

/// 视觉抓拍与多模态相机服务端口 (Camera Port)
///
/// 定义场景拍照、相机状态监测与设备配置契约。
abstract interface class CameraPort {
  bool get isCameraOpen;
  Future<CameraCaptureResult> capturePhoto();
  void applyConfig(VisionConfig config);
  void dispose();
}
