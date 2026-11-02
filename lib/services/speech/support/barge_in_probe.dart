import '../../../core/platform/foundation_bridge.dart';
import '../asr_service.dart';
import 'audio_segment_buffer.dart';
import 'tse_applier.dart';

/// 播报期滚动短窗打断探针。
///
/// 背景：助手外放长段消息时，扬声器声音持续进入麦克风，VAD 永远凑不够
/// 0.5s 尾静音而一直不切段。此处每累积 0.8s 音频且 VAD 未自然切段时，
/// 从预卷环截取最近 1.8s 窗口（前后窗重叠 1.0s）送检，确保用户随时喊
/// “小曼”都能在 <1s 内被识别并打断播报。
///
/// 职责边界：只负责“攒够步长 → 截窗 → 送检 → 回调文本”这条探针链路。
/// 不负责：是否处于倾听态/播报态、ASR 引擎类型判断、VAD 切段与转写互斥，
/// 这些前置条件由 `VoiceListeningService` 判定。
class BargeInProbe {
  BargeInProbe({
    required this.asrService,
    required this.buffer,
    required this.tse,
    required this.isPlaying,
    required this.isInCooldown,
    required this.isTranscribing,
    required this.onTextRecognized,
    required this.onRecognizedAudio,
    required this.postRollMs,
  });

  /// 每次短窗探针截取最近 1.8 秒（28800 采样点 @ 16kHz）送检。
  static const int windowSamples = 28800;

  /// 每新流入 0.8 秒（12800 采样点）触发一次探针，前后两窗重叠 1.0 秒，
  /// 确保约 0.5 秒的“小曼”绝不会被卡在两个窗口接缝处截断。
  static const int stepSamples = 12800;

  /// 音频环中至少攒够 0.8 秒才启动首次探针。
  static const int minRingSamples = 12800;

  final AsrService Function() asrService;
  final AudioSegmentBuffer buffer;
  final TseApplier tse;
  final bool Function() isPlaying;
  final bool Function() isInCooldown;
  final bool Function() isTranscribing;
  final void Function(String text) onTextRecognized;
  final void Function(Float32List audio) onRecognizedAudio;

  /// 尾垫时长；运行期可被 `applyConfig` 改动，必须每次读取。
  final int Function() postRollMs;

  int _samplesSinceLastProbe = 0;
  bool _probing = false;

  /// 清零步长计数（新段开始、缓冲清空时调用）。
  void resetCounter() {
    _samplesSinceLastProbe = 0;
  }

  /// 喂入新到音频的采样点数，满足条件时触发一次探针。
  Future<void> probe(int addedSamples) async {
    if (!isPlaying()) {
      _samplesSinceLastProbe = 0;
      return;
    }
    if (isInCooldown()) {
      _samplesSinceLastProbe = 0;
      return;
    }

    _samplesSinceLastProbe += addedSamples;
    if (_samplesSinceLastProbe < stepSamples) return;
    if (buffer.recentLength < minRingSamples) return;
    if (isTranscribing() || _probing) return;

    _samplesSinceLastProbe = 0;
    final slice = buffer.tail(windowSamples);
    if (slice.isEmpty || isNearSilence(slice)) return;

    _probing = true;
    try {
      final processed = tse.apply(
        buffer.appendTailSilence(slice, postRollMs: postRollMs()),
      );
      if (TseApplier.isZeroed(processed)) return;
      final text = await asrService().transcribeSamples(
        processed,
        sampleRate: 16000,
        isStandbyWakeCheck: true,
        fromVad: true,
      );
      if (text.isNotEmpty && !isInCooldown() && isPlaying()) {
        onRecognizedAudio(processed);
        debugPrint(
          '[VoiceListeningService] 播报期短窗探针 (${slice.length ~/ 16}ms) 识别出文本: "$text"',
        );
        onTextRecognized(text);
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 播报期短窗探针异常: $e\n$st');
    } finally {
      _probing = false;
    }
  }
}
