import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../../core/ports/prompt_sound_port.dart';
import '../../core/platform/audio_output_bridge.dart';

/// 提示音服务：负责在指令识别完成（如确认识别到“回答”）后，立即播放柔和清脆的“轻滴声”提示音
class PromptSoundService implements PromptSoundPort {
  static Uint8List? _cachedBeepWav;
  PlatformSoundPlayer? _player;
  String outputDeviceId;

  PromptSoundService({this.outputDeviceId = ''});

  /// 生成或获取 130ms 高频柔和水滴/提示音 WAV 字节 (纯 Dart 内存生成，无外部资产依赖)
  /// 采样率 22050Hz, 16-bit 单声道 PCM
  /// 基频 1046.5Hz (高音 C6) + 1318.5Hz (E6 大三度微弱泛音) + 2093.0Hz (C7 八度泛音)
  /// 带有 5ms 线性上升沿淡入，以及自然指数衰减淡出，音色轻灵柔和、不刺耳、极度轻快
  static Uint8List getBeepWavBytes() {
    if (_cachedBeepWav != null) return _cachedBeepWav!;

    const sampleRate = 22050;
    const durationSeconds = 0.13; // 130ms 极短轻快
    final totalSamples = (sampleRate * durationSeconds).round();

    final pcmBytes = BytesBuilder();
    for (int i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;

      // 5ms 平滑淡入，避免电平跳跃产生爆音
      final attack =
          (i < sampleRate * 0.005) ? (i / (sampleRate * 0.005)) : 1.0;
      // 指数衰减平滑淡出
      final decay = (i < sampleRate * 0.005) ? 1.0 : exp(-(t - 0.005) * 25.0);
      final envelope = attack * decay;

      // 主音 1046.5Hz (C6) 配合微量泛音构成清脆提示铃音
      final wave = 0.72 * sin(2 * pi * 1046.5 * t) +
          0.18 * sin(2 * pi * 1318.51 * t) +
          0.10 * sin(2 * pi * 2093.0 * t);

      final sample = (wave * envelope * 24000).clamp(-32768, 32767).toInt();

      // 16-bit Little Endian
      pcmBytes.addByte(sample & 0xFF);
      pcmBytes.addByte((sample >> 8) & 0xFF);
    }

    _cachedBeepWav = _buildMono16Wav(pcmBytes.toBytes(), sampleRate);
    return _cachedBeepWav!;
  }

  static Uint8List? _cachedShutterWav;

  /// 生成或获取 120ms 机械相机快门声（咔嚓声）WAV 字节 (纯 Dart 内存生成)
  /// 采用双脉冲机械声学模型：前段开闸点击 (25ms) + 短暂静默间隙 (30ms) + 后段落闸点击 (35ms)
  static Uint8List getShutterWavBytes() {
    if (_cachedShutterWav != null) return _cachedShutterWav!;

    const sampleRate = 22050;
    const durationSeconds = 0.12; // 120ms 极快脆响
    final totalSamples = (sampleRate * durationSeconds).round();

    final pcmBytes = BytesBuilder();
    final random = Random(42);

    for (int i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      double sampleValue = 0.0;

      // 脉冲 1: 开闸声音 (0 ~ 28ms)
      if (t < 0.028) {
        final t1 = t;
        final env = exp(-t1 * 140.0);
        final click = sin(2 * pi * 2400.0 * t1) * 0.6 +
            (random.nextDouble() * 2 - 1) * 0.4;
        sampleValue += click * env;
      }
      // 脉冲 2: 落闸声音 (48ms ~ 95ms)
      else if (t >= 0.048 && t < 0.095) {
        final t2 = t - 0.048;
        final env = exp(-t2 * 110.0);
        final click = sin(2 * pi * 1700.0 * t2) * 0.5 +
            (random.nextDouble() * 2 - 1) * 0.5;
        sampleValue += click * env;
      }

      final sample = (sampleValue * 26000).clamp(-32768, 32767).toInt();
      pcmBytes.addByte(sample & 0xFF);
      pcmBytes.addByte((sample >> 8) & 0xFF);
    }

    _cachedShutterWav = _buildMono16Wav(pcmBytes.toBytes(), sampleRate);
    return _cachedShutterWav!;
  }

  static Uint8List _buildMono16Wav(Uint8List pcmData, int sampleRate) {
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final header = ByteData(44);
    // RIFF chunk descriptor
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, fileSize, Endian.little);
    // WAVE
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'
    // 'fmt ' subchunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    header.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    header.setUint16(22, 1, Endian.little); // NumChannels (1 mono)
    header.setUint32(24, sampleRate, Endian.little); // SampleRate
    header.setUint32(28, sampleRate * 2,
        Endian.little); // ByteRate (sampleRate * 1 * 16 / 8)
    header.setUint16(32, 2, Endian.little); // BlockAlign (1 * 16 / 8)
    header.setUint16(34, 16, Endian.little); // BitsPerSample
    // 'data' subchunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, dataSize, Endian.little);

    final wavBuilder = BytesBuilder(copy: false);
    wavBuilder.add(header.buffer.asUint8List());
    wavBuilder.add(pcmData);
    return wavBuilder.toBytes();
  }

  /// 立即播放确认提示音（轻滴声）
  @override
  Future<void> playAcknowledgeBeep() =>
      _playWavBytes(getBeepWavBytes(), tag: 'beep');

  /// 立即播放相机拍照快门声（咔嚓声）
  @override
  Future<void> playShutterSound() =>
      _playWavBytes(getShutterWavBytes(), tag: 'shutter');

  Future<void> _playWavBytes(Uint8List wav, {String tag = 'tone'}) async {
    try {
      _player ??= PlatformSoundPlayer(outputDeviceId: outputDeviceId);
      _player!.outputDeviceId = outputDeviceId;
      await _player!.playWavBytes(wav, tag: tag);
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _player?.dispose();
    } catch (_) {}
  }
}
