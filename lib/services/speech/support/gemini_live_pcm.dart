import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Gemini Live 实时音频编码工具（纯计算、无状态）。
///
/// 职责边界：只负责 Float32 采样 → 16bit 小端 PCM 的转换、重采样，以及
/// `realtimeInput.audio` 帧的组装；不持有 socket、不涉及发送节奏。
class GeminiLivePcm {
  const GeminiLivePcm._();

  /// 每帧 100ms @ 16kHz PCM16。
  static const int bytesPerChunk = 1600 * 2;

  /// 组装一条 `realtimeInput.audio` 消息（[offset, end) 为 PCM 字节区间）。
  static String encodeChunkMessage(Uint8List pcm, int offset, int end) {
    return jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
        },
      },
    });
  }

  /// Float32 [-1, 1] 采样 → 16bit 小端 PCM 字节。
  static Uint8List float32ToPcm16(Float32List samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0).toDouble();
      data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return bytes;
  }

  /// 线性插值重采样（ASR 只接受 16k）。
  static Float32List resample(
    Float32List input, {
    required int fromRate,
    required int toRate,
  }) {
    if (input.isEmpty || fromRate == toRate || fromRate <= 0 || toRate <= 0) {
      return input;
    }
    final outLength = (input.length * toRate / fromRate).round();
    final output = Float32List(outLength);
    final ratio = fromRate / toRate;
    for (var i = 0; i < outLength; i++) {
      final position = i * ratio;
      final index = position.floor();
      final next = math.min(index + 1, input.length - 1);
      final fraction = position - index;
      output[i] = input[index] * (1 - fraction) + input[next] * fraction;
    }
    return output;
  }
}
