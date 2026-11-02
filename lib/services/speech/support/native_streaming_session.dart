import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../../../core/platform/foundation_bridge.dart';
import '../asr_service.dart';
import 'audio_segment_buffer.dart';

/// 内置流式识别器（Zipformer 等 `isStreaming` 引擎）的在线解码会话。
///
/// 职责边界：
/// - 持有 `OnlineStream`，按块 `acceptWaveform` + `decode` + `getResult`；
/// - 文本去重后回调，并把本次识别的原始音频一并交出（供声纹比对）；
/// - 播报长语音期间主动滚动重置并回填重叠音频，避免流式束搜索退化；
/// - 端点命中后把整段音频交给两遍解码复检，并复位识别器。
///
/// 不负责：VAD 切段、静音冷却窗的计时、flush 代际、采集链路与看门狗。
class NativeStreamingSession {
  NativeStreamingSession({
    required this.asrService,
    required this.buffer,
    required this.hotwords,
    required this.isStandby,
    required this.isPlaying,
    required this.isMicTesting,
    required this.isEnrollingSpeaker,
    required this.isInCooldown,
    required this.onTextRecognized,
    required this.onRecognizedAudio,
    required this.onFinalPass,
    this.onMicTestRecognized,
  });

  /// 运行期可能被 `setAsrService` 替换，必须每次读取。
  final AsrService Function() asrService;
  final AudioSegmentBuffer buffer;
  final String Function() hotwords;
  final bool Function() isStandby;
  final bool Function() isPlaying;
  final bool Function() isMicTesting;
  final bool Function() isEnrollingSpeaker;
  final bool Function() isInCooldown;
  final void Function(String text) onTextRecognized;

  /// 本次识别对应的原始音频（供声纹比对校验）。
  final void Function(Float32List audio) onRecognizedAudio;

  /// 端点命中后触发两遍解码的第二遍（复检）。
  final void Function(Float32List audio) onFinalPass;
  final void Function(String text, int durationMs)? onMicTestRecognized;

  sherpa_onnx.OnlineStream? _stream;
  String _lastText = '';

  /// 确保在线流已创建（首次启动监听、切换引擎后调用）。
  void ensureStream() {
    _stream ??= asrService().createOnlineStream(hotwords: hotwords());
  }

  /// 释放底层在线流。
  void free() {
    _stream?.free();
    _stream = null;
    _lastText = '';
  }

  /// 复位识别器输入状态并清空整段缓冲。
  void reset() {
    final stream = _stream;
    final recognizer = asrService().onlineRecognizer;
    if (stream != null && recognizer != null) {
      try {
        recognizer.reset(stream);
      } catch (_) {}
    }
    _lastText = '';
    buffer.clearUtterance();
  }

  /// 送入一块 16k 单声道音频并推进解码。
  void accept(Float32List samples) {
    ensureStream();
    final stream = _stream;
    if (stream == null) return;

    final recognizer = asrService().onlineRecognizer;
    if (recognizer == null) return;

    stream.acceptWaveform(samples: samples, sampleRate: 16000);

    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }

    final result = recognizer.getResult(stream);
    final rawText = result.text.trim();
    final playing = isPlaying();
    final standby = isStandby();
    final text = rawText.isEmpty
        ? ''
        : postProcessAsrText(
            rawText,
            wakeContext: isMicTesting() ? false : (standby || playing),
          );

    if (text.isNotEmpty &&
        text != _lastText &&
        !isInCooldown() &&
        !isEnrollingSpeaker()) {
      _lastText = text;
      onRecognizedAudio(buffer.utteranceLength >= 9600
          ? buffer.utteranceSnapshot()
          : buffer.recent(seconds: 2.5));
      debugPrint('[VoiceListeningService] 原生流式实时识别: "$text"');
      onMicTestRecognized?.call(text, 0);
      if (!isMicTesting()) {
        onTextRecognized(text);
      }
    }

    // 播报长语音期间扬声器无长静音，流式解码器可能迟迟不命中 isEndpoint；
    // 当单段累积超过 36 字且尚未打断时主动滚动重置，并回填最近 0.6s 重叠音频，
    // 防止流式束搜索因长回声退化，同时保证跨重置边界的“小曼”不被切断。
    if (playing && rawText.length >= 36 && !recognizer.isEndpoint(stream)) {
      final overlap = buffer.utteranceTail(9600);
      reset();
      final current = _stream;
      if (overlap.isNotEmpty && current != null) {
        buffer.addUtterance(overlap);
        current.acceptWaveform(samples: overlap, sampleRate: 16000);
      }
      return;
    }

    if (recognizer.isEndpoint(stream)) {
      debugPrint('[VoiceListeningService] 流式 ASR 命中端点断句 (isEndpoint): "$text"');
      // 两遍解码：端点命中后，把整段音频交给内置 SenseVoice 复检。
      final finalAudio = buffer.utteranceLength >= 16000 * 0.2
          ? buffer.utteranceSnapshot()
          : Float32List(0);
      // 无论是否识别出文字都必须复位，否则识别器会停留在端点状态导致后续音频错位。
      reset();
      if (finalAudio.isNotEmpty) {
        onFinalPass(finalAudio);
      }
    }
  }
}
