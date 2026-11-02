import 'dart:async';

import '../../../core/platform/foundation_bridge.dart';
import '../asr_service.dart';
import 'audio_segment_buffer.dart';

/// 边说边传（Gemini 等云端实时引擎）会话。
///
/// 职责边界：
/// - VAD 一判定“正在说话”就开始推流，而不是等切完段；
/// - 开流时从预卷环补齐“预卷 + 已说出的部分”，避免句首被 VAD 判定延迟削掉；
/// - 说话结束时把最后一个静音块也送进去并串行收尾；
/// - 云端没接住（连接失败/超时）时，用 VAD 弹出的整段音频回退整段识别；
/// - 跨越缓冲清空（flush 代际变化）的陈旧结果直接丢弃。
///
/// 不负责：VAD 自身的判定与切段、冷却窗计时、flush 代际的递增，
/// 这些仍由 `VoiceListeningService` 掌握（时序耦合强）。
class LiveUtteranceSession {
  LiveUtteranceSession({
    required this.asrService,
    required this.buffer,
    required this.isStandby,
    required this.isPlaying,
    required this.isMicTesting,
    required this.isEnrollingSpeaker,
    required this.isInCooldown,
    required this.flushGeneration,
    required this.isListening,
    required this.standbyHint,
    required this.onStateChanged,
    required this.onTextRecognized,
    required this.onRecognizedAudio,
    this.onMicTestRecognized,
  });

  /// 运行期可能被 `setAsrService` 替换，必须每次读取。
  final AsrService Function() asrService;
  final AudioSegmentBuffer buffer;
  final bool Function() isStandby;
  final bool Function() isPlaying;
  final bool Function() isMicTesting;
  final bool Function() isEnrollingSpeaker;
  final bool Function() isInCooldown;
  final int Function() flushGeneration;
  final bool Function() isListening;
  final String Function() standbyHint;
  final void Function(bool isListening, String statusHint)? onStateChanged;
  final void Function(String text) onTextRecognized;

  /// 本次识别对应的原始音频（供声纹比对校验）。
  final void Function(Float32List audio) onRecognizedAudio;
  final void Function(String text, int durationMs)? onMicTestRecognized;

  bool _active = false;
  Future<void> _finishQueue = Future<void>.value();

  /// 边说边传进行中时 VAD 弹出的那一段音频；live 失败时用它整段回退识别。
  Float32List? _lastVadSegmentAudio;

  /// 当前是否处于一段“边说边传”中。
  bool get isActive => _active;

  /// VAD 切出的整段音频（live 期间的失败回退素材）。
  void setVadSegment(Float32List audio) {
    _lastVadSegmentAudio = audio;
  }

  /// 清空 live 状态（不主动收尾，由调用方决定丢弃还是收尾）。
  void reset() {
    _active = false;
    _lastVadSegmentAudio = null;
  }

  /// 丢弃当前 live 段：直接结束云端会话，结果不再使用。
  void discard() {
    if (_active) {
      _active = false;
      unawaited(asrService().endLiveUtterance());
    }
    _lastVadSegmentAudio = null;
  }

  /// 喂入一块音频，并按 VAD 判定推进“开流 / 追加 / 收尾”。
  void pump(
    Float32List samples, {
    required bool vadDetected,
    required int preRollMs,
    required double vadMinSpeechSeconds,
  }) {
    if (vadDetected) {
      if (!_active) {
        _active = true;
        _lastVadSegmentAudio = null;
        // VAD 要累积 minSpeechDuration 才置位，真正开口在更早；从预卷环里把
        // “预卷 + 已说出的部分”一次性补齐，避免句首被 VAD 的判定延迟削掉。
        final backfillMs =
            preRollMs + (vadMinSpeechSeconds * 1000).round() + 120;
        final backfill = buffer.tail(backfillMs * 16);
        final playing = isPlaying();
        final standby = isStandby();
        if (!playing) {
          onStateChanged?.call(true, '检测到声音，正在识别...');
        }
        // 播报期间必须将 isStandbyWakeCheck 设为 false 以开启云端实时中间结果 (onPartialText)，
        // 从而无需等待外放静音即可实时探测“小曼”打断词。
        asrService().beginLiveUtterance(
          backfill,
          isStandbyWakeCheck: standby && !playing,
        );
      } else {
        asrService().appendLiveAudio(samples);
      }
      return;
    }

    if (_active) {
      // 触发“结束”的最后一个静音块也要送进去，保证模型听到完整尾音。
      asrService().appendLiveAudio(samples);
      _active = false;
      final fallback = _lastVadSegmentAudio;
      _lastVadSegmentAudio = null;
      final standby = isStandby();
      final flushGen = flushGeneration();
      _finishQueue = _finishQueue.then(
        (_) => _finish(
          fallbackAudio: fallback,
          isStandby: standby,
          flushGen: flushGen,
        ),
        onError: (Object _, StackTrace __) {},
      );
    }
  }

  Future<void> _finish({
    required Float32List? fallbackAudio,
    required bool isStandby,
    required int flushGen,
  }) async {
    final started = DateTime.now();
    try {
      final text = await asrService().endLiveUtterance();
      debugPrint(
        '[VoiceListeningService] 边说边传收尾耗时 '
        '${DateTime.now().difference(started).inMilliseconds}ms',
      );
      if (flushGen != flushGeneration()) {
        if (text != null && text.isNotEmpty) {
          debugPrint('[VoiceListeningService] 已丢弃跨越缓冲清空的陈旧语音片段: "$text"');
        }
        return;
      }
      if (text != null) {
        // 非空 = 云端给出了最终文本；空串 = 识别到了但不可用（非中文），直接丢弃。
        if (text.isNotEmpty && !isInCooldown() && !isEnrollingSpeaker()) {
          onRecognizedAudio(fallbackAudio ?? buffer.recent(seconds: 3.0));
          debugPrint('[VoiceListeningService] 边说边传识别出文本: "$text"');
          onMicTestRecognized?.call(
            text,
            DateTime.now().difference(started).inMilliseconds,
          );
          if (!isMicTesting()) {
            onTextRecognized(text);
          }
        }
        return;
      }

      // 云端没接住（连接失败/超时）：用刚才 VAD 弹出的整段音频回退识别。
      if (fallbackAudio == null || fallbackAudio.isEmpty) return;
      if (flushGen != flushGeneration()) return;
      debugPrint('[VoiceListeningService] 边说边传未返回结果，回退整段识别');
      final fallbackText = await asrService().transcribeSamples(
        fallbackAudio,
        sampleRate: 16000,
        isStandbyWakeCheck: isMicTesting() ? false : isStandby,
        fromVad: true,
      );
      if (fallbackText.isNotEmpty &&
          flushGen == flushGeneration() &&
          !isInCooldown() &&
          !isEnrollingSpeaker()) {
        onRecognizedAudio(fallbackAudio);
        onMicTestRecognized?.call(
          fallbackText,
          DateTime.now().difference(started).inMilliseconds,
        );
        if (!isMicTesting()) {
          onTextRecognized(fallbackText);
        }
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 边说边传收尾异常: $e\n$st');
    } finally {
      if (isListening() && !_active) {
        onStateChanged?.call(true, standbyHint());
      }
    }
  }
}
