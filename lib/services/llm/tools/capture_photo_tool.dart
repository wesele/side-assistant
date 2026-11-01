import '../../../core/models/app_settings.dart';
import '../../../core/ports/llm_tool.dart';

/// 随身相机实时抓拍工具适配器 (CapturePhotoTool)
///
/// 依赖 [LlmToolContext.onCapturePhoto] 与 [LlmToolContext.onPhotoCaptured]，
/// 严格遵循纯 Dart 无头环境规范。
class CapturePhotoTool implements LlmTool {
  const CapturePhotoTool();

  @override
  String get name => 'capture_photo';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'capture_photo',
      'description':
          '调用随身摄像头拍摄当前现场照片。当且仅当主人在最新一条提问中明确要求你“拍张照”、“拍照看看”、“识别面前的新物体/文字/现场画面”时调用。若主人只是针对上一张照片或已有讨论进行追问、闲聊或无需新画面的问题，严禁调用该工具。',
      'parameters': {
        'type': 'object',
        'properties': {
          'reason': {
            'type': 'string',
            'description': '调用拍照的具体原因或要观察的目标（例如“拍摄面前的植物辨识品种”）。',
          },
        },
      },
    },
  };

  @override
  Map<String, dynamic> get definition => toolDefinition;

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) {
    return context?.onCapturePhoto != null;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    final captureFn = context?.onCapturePhoto;
    if (captureFn == null) {
      return '拍照失败：未配置拍照功能或相机不可用。';
    }
    try {
      final photoBytes = await captureFn();
      if (photoBytes != null && photoBytes.isNotEmpty) {
        context?.onPhotoCaptured?.call(photoBytes);
        return '现场照片拍摄成功，画面已发送。';
      } else {
        return '拍照失败：未能获取到相机画面。';
      }
    } catch (e) {
      return '拍照异常：$e';
    }
  }
}
