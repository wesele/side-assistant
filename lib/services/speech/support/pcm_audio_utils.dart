import 'dart:math' as math;
import 'dart:typed_data';

/// 一次 PCM 回调的电平快照（供 UI 电平条与 VAD 指示使用）。
class AudioLevel {
  const AudioLevel({
    required this.level,
    required this.dbfs,
    required this.rms,
  });

  /// 归一化电平 0.0~1.0（把 -55dBFS~-5dBFS 映射到 0~1）。
  final double level;

  /// dBFS，钳制在 -60~0。
  final double dbfs;

  /// 原始均方根能量。
  final double rms;
}

/// PCM 字节/采样点的纯计算工具。
///
/// 职责边界：只做 16bit PCM 解包与 RMS/dBFS/归一化电平计算，
/// 不持有状态、不涉及 VAD 判定与采集链路。
class PcmAudioUtils {
  const PcmAudioUtils._();

  /// 16bit 小端 PCM 字节 → [-1, 1) 的浮点采样。
  static Float32List pcm16ToFloat32(Uint8List bytes) {
    final numSamples = bytes.length ~/ 2;
    if (numSamples == 0) return Float32List(0);
    final byteData = ByteData.sublistView(bytes);
    final floatList = Float32List(numSamples);
    for (int i = 0; i < numSamples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      floatList[i] = sample / 32768.0;
    }
    return floatList;
  }

  /// 计算 RMS / dBFS / 归一化电平。
  static AudioLevel measureLevel(Float32List samples) {
    double sumSq = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i];
      sumSq += s * s;
    }
    final rms = math.sqrt(sumSq / samples.length);
    final dbfs =
        (20.0 * math.log(math.max(rms, 1e-5)) / math.ln10).clamp(-60.0, 0.0);
    final level = ((dbfs + 55.0) / 50.0).clamp(0.0, 1.0);
    return AudioLevel(level: level, dbfs: dbfs, rms: rms);
  }
}
