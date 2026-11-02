import 'dart:math' as math;
import 'dart:typed_data';

import '../audio_ring.dart';

/// 语音切段缓冲：预卷环、整段环，以及「VAD 段 → 送 ASR 片段」的拼装规则。
///
/// 职责边界（纯数据搬运，不依赖 ASR / VAD / 平台插件 / 全局设置对象）：
/// - 维护最近 [capacitySamples] 个采样点的连续 PCM 环，供 VAD 段补预卷、
///   播报期短窗探针、边说边传回填使用；
/// - 维护「当前整段」环，供流式识别与两遍解码复检取整段音频；
/// - 把 VAD 弹出的段拼成送识别器的片段：段首补 [preRollMs]、段尾补 [postRollMs]。
///
/// 不负责：VAD 状态、静音冷却窗、flush 代际、ASR 调用等时序逻辑，
/// 这些仍留在 `VoiceListeningService`（时序耦合强，抽出去反而更难维护）。
class AudioSegmentBuffer {
  AudioSegmentBuffer({this.capacitySamples = 35 * 16000})
      : _recent = AudioRing(capacitySamples),
        _utterance = AudioRing(capacitySamples);

  /// 全局采样率，所有毫秒换算都以它为基准。
  static const int sampleRate = 16000;

  /// 单个环的容量（采样点数）。
  final int capacitySamples;

  final AudioRing _recent;
  final AudioRing _utterance;

  /// 预卷环中当前有效采样点数。
  int get recentLength => _recent.length;

  /// 整段环中当前有效采样点数。
  int get utteranceLength => _utterance.length;

  /// 追加最新到达的 PCM。
  void addRecent(Float32List samples) => _recent.add(samples);

  /// 追加到整段缓冲。
  void addUtterance(Float32List samples) => _utterance.add(samples);

  /// 清空预卷环。
  void clearRecent() => _recent.clear();

  /// 清空整段缓冲。
  void clearUtterance() => _utterance.clear();

  /// 最近 [seconds] 秒的连续 PCM 切片；环为空时返回空数组。
  Float32List recent({double seconds = 2.5}) {
    final requestedSamples = (seconds * sampleRate).round();
    if (_recent.length <= 0) return Float32List(0);
    final start = math.max(0, _recent.length - requestedSamples);
    return _recent.slice(start, _recent.length);
  }

  /// 预卷环尾部最多 [samples] 个采样点（不足时返回全部）。
  Float32List tail(int samples) {
    final len = math.min(_recent.length, samples);
    if (len <= 0) return Float32List(0);
    return _recent.slice(_recent.length - len, _recent.length);
  }

  /// 整段缓冲的完整副本。
  Float32List utteranceSnapshot() => _utterance.snapshot();

  /// 整段缓冲尾部最多 [samples] 个采样点（不足时返回全部）。
  Float32List utteranceTail(int samples) {
    final len = math.min(_utterance.length, samples);
    if (len <= 0) return Float32List(0);
    return _utterance.slice(_utterance.length - len, _utterance.length);
  }

  /// 从预卷环中截取 VAD 段之前的 [preRollMs] 毫秒音频。
  ///
  /// VAD 在检测到 [vadMinSilenceSeconds] 的尾静音后才输出段，因此：
  ///   段尾 ≈ 环尾 - 尾静音
  ///   段首 ≈ 段尾 - segment.length
  /// 再往前取 preRollMs 即为需要补回的预卷。
  Float32List prependPreRoll(
    Float32List segment, {
    required int preRollMs,
    required double vadMinSilenceSeconds,
    required double vadMaxSpeechSeconds,
  }) {
    final preRollSamples = (preRollMs * 16).clamp(0, 16000);
    if (preRollSamples <= 0 || _recent.length <= 0) return segment;

    // 达到 maxSpeechDuration 被强制切段的，尾部没有尾静音，反推段首会错位；
    // 这种情况下不补预卷，避免把段内音频重复送进模型。
    if (segment.length >= vadMaxSpeechSeconds * sampleRate * 0.95) {
      return segment;
    }

    final silenceSamples = (vadMinSilenceSeconds * sampleRate).round();
    final segmentEnd = _recent.length - silenceSamples;
    final segmentStart = segmentEnd - segment.length;
    if (segmentStart <= 0) return segment;

    final start = math.max(0, segmentStart - preRollSamples);
    if (start >= segmentStart) return segment;

    final pre = _recent.slice(start, segmentStart);
    final out = Float32List(pre.length + segment.length);
    out.setRange(0, pre.length, pre);
    out.setRange(pre.length, out.length, segment);
    return out;
  }

  /// 在段尾补一小段静音，帮助 CTC/注意力模型收尾。
  Float32List appendTailSilence(Float32List segment,
      {required int postRollMs}) {
    final tailSamples = (postRollMs * 16).clamp(0, 16000);
    if (tailSamples <= 0) return segment;
    final out = Float32List(segment.length + tailSamples);
    out.setRange(0, segment.length, segment);
    return out;
  }
}
