import 'dart:async';

import '../../../ports/tts_port.dart';

/// TTS 流式分句切片与播报缓冲器 (StreamingSentenceSegmenter)
///
/// 职责：
/// 1. 累加大模型流式生成的 chunk token；
/// 2. 基于标点边界正则切分子句（[。！？\n!?]）；
/// 3. 门限控制（默认 >= 4 字符）避免短碎片导致发音生硬；
/// 4. 将就绪子句按产生顺序推入 [TtsPort.enqueueSentence] 队列；
/// 5. 流结束时冲刷并排队剩余文本碎片。
///
/// 纯 Dart 实现，零 dart:ui / package:flutter 依赖。
class StreamingSentenceSegmenter {
  /// 标点切句边界正则（中英文问号、感叹号、句号、换行）
  static final RegExp sentenceBoundaryRegExp = RegExp(r'[。！？\n!?]');

  /// 最小切句有效字符门限（低于此长度暂缓切句，等待累积）
  static const int defaultMinSentenceLength = 4;

  final TtsPort? ttsService;
  final int minSentenceLength;
  final StringBuffer _buffer = StringBuffer();

  /// 调试/测试监听钩子（当子句被成功切分并推入 TTS 时触发）
  final void Function(String sentence)? onSentenceEnqueued;

  /// 调试监听钩子（子句已切分完成、但当前状态不允许入队播报而暂存时触发）
  final void Function(String sentence)? onSentenceSuppressed;

  StreamingSentenceSegmenter({
    this.ttsService,
    this.minSentenceLength = defaultMinSentenceLength,
    this.onSentenceEnqueued,
    this.onSentenceSuppressed,
  });

  /// 当前缓冲区内尚未被标点切分的残余文本
  String get bufferedText => _buffer.toString();

  /// 缓冲区内是否有待处理文本
  bool get hasBufferedText => _buffer.isNotEmpty;

  /// 缓冲区是否为空
  bool get isEmpty => _buffer.isEmpty;

  /// 清空当前分句缓冲区
  void reset() {
    _buffer.clear();
  }

  /// 接收大模型流式吐出的新片段并尝试切句入队
  ///
  /// [chunk] 新到达的文本片段；
  /// [shouldCancel] 代系或状态取消回调；
  /// [canEnqueue] 当前是否允许将切好的句子送入 TTS 播报队列（如状态为 playing 且代系匹配）。
  /// 返回本次成功切分出的句子列表。
  List<String> feedChunk(
    String chunk, {
    bool Function()? shouldCancel,
    bool Function()? canEnqueue,
  }) {
    if (chunk.isEmpty) return const [];
    _buffer.write(chunk);

    final currentText = _buffer.toString();
    final matches = sentenceBoundaryRegExp.allMatches(currentText);
    if (matches.isEmpty) return const [];

    final lastMatch = matches.last;
    final readySentence = currentText.substring(0, lastMatch.end);
    if (readySentence.trim().length < minSentenceLength) {
      return const [];
    }

    // 当前不允许入队播报（状态已离开 playing / 代系不匹配）时，**不要把句子从缓冲区里摘走**。
    // 旧实现会先清空缓冲区再判断门禁，导致这类句子被静默丢弃、本轮彻底没有声音，
    // 且日志里毫无痕迹。保留在缓冲区里交给 flush 统一决策，最坏情况会走整段兜底播报。
    final allowed = canEnqueue?.call() ?? true;
    if (!allowed) {
      onSentenceSuppressed?.call(readySentence);
      return const [];
    }

    final remainder = currentText.substring(lastMatch.end);
    _buffer
      ..clear()
      ..write(remainder);

    final readySentences = [readySentence];
    if (ttsService != null) {
      ttsService!.enqueueSentence(
        readySentence,
        shouldCancel: shouldCancel ?? () => false,
      );
    }
    onSentenceEnqueued?.call(readySentence);
    return readySentences;
  }

  /// 冲刷并返回缓冲区中剩余的末尾文本碎片
  String flushRemaining() {
    final remaining = _buffer.toString().trim();
    _buffer.clear();
    return remaining;
  }

  /// 流式传输完毕时清空缓冲区中的余下碎片，并可选等待 TTS 全部播报完毕
  ///
  /// [shouldCancel] 代系或状态取消回调；
  /// [canEnqueue] 是否允许入队播报；
  /// [waitForCompletion] 是否阻塞等待 TTS 完成队列播放。
  Future<String> flush({
    bool Function()? shouldCancel,
    bool Function()? canEnqueue,
    bool waitForCompletion = false,
  }) async {
    final remaining = flushRemaining();
    final allowed = canEnqueue?.call() ?? true;
    if (remaining.isNotEmpty && allowed) {
      ttsService?.enqueueSentence(
        remaining,
        shouldCancel: shouldCancel ?? () => false,
      );
      onSentenceEnqueued?.call(remaining);
    }

    if (waitForCompletion && allowed) {
      await ttsService?.waitForCompletion();
    }
    return remaining;
  }
}
