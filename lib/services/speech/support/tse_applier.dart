import '../../../core/platform/foundation_bridge.dart';
import '../../../core/ports/target_speaker_extraction_port.dart';

/// 目标说话人抽取（TSE）后处理。
///
/// 职责边界：
/// - 判断“是否该跑 TSE”（服务已注入、设置已开启、主人声纹已注册、音频非空）；
/// - 调用抽取并在异常时放行原音频（识别链路不能因为 TSE 崩溃而中断）；
/// - 判定抽取结果是否被明确置零（纯 0.0 数组），供调用方丢弃非目标语音。
///
/// 不负责：VAD 切段、静音冷却窗、ASR 调用等时序逻辑。
class TseApplier {
  TseApplier({required this.service, required this.isEnabled});

  final TargetSpeakerExtractionPort? service;

  /// 运行期读取设置（`applyConfig` 会整体替换 `settings.audio`，不能缓存）。
  final bool Function() isEnabled;

  /// 若开启 TSE 且已注册主人声纹，从混音中剥离出主人的声音；否则原样返回。
  Float32List apply(Float32List audio) {
    final tse = service;
    if (tse == null || !isEnabled() || !tse.hasEnrolledOwner || audio.isEmpty) {
      return audio;
    }
    try {
      return tse.extractTargetSpeaker(audio);
    } catch (e) {
      debugPrint('[VoiceListeningService] TSE 目标说话人抽取异常，放行原音频: $e');
      return audio;
    }
  }

  /// 检查音频是否被 TSE 明确置零静音（纯 0.0 数组）。
  ///
  /// 仅丢弃 TSE 明确滤除的非目标人声/电视声，避免将远场或微弱麦克风
  /// （如蓝牙音箱麦克风）的声音误杀。
  static bool isZeroed(Float32List samples) {
    if (samples.isEmpty) return true;
    for (var i = 0; i < samples.length; i++) {
      if (samples[i] != 0.0) return false;
    }
    return true;
  }
}
