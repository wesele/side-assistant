import 'dart:io';

import '../../../core/platform/audio_recorder_bridge.dart';
import '../../../core/platform/storage_bridge.dart';
import '../asr_service.dart';

/// 手动单次录音（对讲模式）：录到 wav 文件后立刻走本地离线识别。
///
/// 职责边界：
/// - 维护“是否正在手动录音”状态；
/// - 开始前停掉持续监听、校验麦克风权限、解析录音设备；
/// - 停止时取回文件、送 ASR、删除临时文件并回调结果。
///
/// 不负责：持续监听/VAD 的时序（由调用方通过 [stopListening] 与
/// [refreshDevice] 注入），也不持有采集流。
class ManualRecordingSession {
  ManualRecordingSession({
    required this.recorder,
    required this.asrService,
    required this.device,
    required this.stopListening,
    required this.hasPermission,
    required this.refreshDevice,
    required this.onTextRecognized,
    this.onManualRecordingRecognized,
    this.onStateChanged,
  });

  final PlatformAudioRecorder recorder;

  /// 运行期可能被 `setAsrService` 替换，必须每次读取。
  final AsrService Function() asrService;
  final PlatformInputDevice? Function() device;

  /// 开始录音前停掉持续监听（未在监听时应为空操作）。
  final Future<void> Function() stopListening;
  final Future<bool> Function() hasPermission;
  final Future<void> Function() refreshDevice;
  final void Function(String text) onTextRecognized;
  final void Function(String text)? onManualRecordingRecognized;
  final void Function(bool isListening, String statusHint)? onStateChanged;

  bool _isRecording = false;

  bool get isRecording => _isRecording;

  /// 开始手动单次录音，返回是否成功启动。
  Future<bool> start() async {
    await stopListening();
    final permitted = await hasPermission();
    if (!permitted) return false;

    await refreshDevice();

    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final manualPath =
        '${tempDir.path}/manual_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      await recorder.startWavFile(path: manualPath, device: device());
      _isRecording = true;
      onStateChanged?.call(true, '正在录音...松开或点击发送');
      return true;
    } catch (e) {
      _isRecording = false;
      return false;
    }
  }

  /// 停止手动录音并立即识别，返回识别文本（失败/取消返回空串）。
  Future<String> stop() async {
    if (!_isRecording) return '';
    _isRecording = false;

    try {
      final path = await recorder.stop();
      if (path != null && File(path).existsSync()) {
        onStateChanged?.call(false, '正在本地离线识别...');
        final recognizedText = await asrService()
            .transcribeAudioFile(path, isStandbyWakeCheck: false);
        try {
          File(path).deleteSync();
        } catch (_) {}

        if (recognizedText.isNotEmpty) {
          final manual = onManualRecordingRecognized;
          if (manual != null) {
            manual(recognizedText);
          } else {
            onTextRecognized(recognizedText);
          }
        }
        onStateChanged?.call(false, '识别完成');
        return recognizedText;
      }
    } catch (_) {}

    onStateChanged?.call(false, '已取消录音');
    return '';
  }
}
