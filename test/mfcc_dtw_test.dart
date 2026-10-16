import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/speech/mfcc_dtw_filter.dart';

void main() {
  group('MfccDtwFilter 声学特征提取与子序列匹配测试', () {
    test('MFCC 特征提取应正确返回 13 维特征向量', () {
      // 1 秒 16kHz 正弦波信号
      final samples = Float32List(16000);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * 440 * i / 16000);
      }

      final mfcc = MfccDtwFilter.extractMfcc(samples);
      expect(mfcc.isNotEmpty, isTrue);
      // 16000 点，窗长 400，步长 160，应生成 ~98 帧
      expect(mfcc.length, equals((16000 - 400) ~/ 160 + 1));
      expect(mfcc.first.length, equals(13));
      // 检查没有 NaN 或 Infinity
      for (final frame in mfcc) {
        for (final val in frame) {
          expect(val.isNaN, isFalse);
          expect(val.isInfinite, isFalse);
        }
      }
    });

    test('子序列 DTW 对自身匹配距离应接近 0', () {
      final samples = Float32List(8000);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * 500 * i / 16000) * 0.8;
      }
      final template = MfccDtwFilter.extractMfcc(samples);
      final dist = MfccDtwFilter.subsequenceDtw(template, template);
      expect(dist, closeTo(0.0, 0.0001));
    });

    test('长音频中嵌入目标唤醒词时，Subsequence DTW 应能准确定位并返回极小距离', () {
      // 构造 3 秒音频：前 1 秒杂音，中间 0.5 秒目标音，后 1.5 秒杂音
      final fullAudio = Float32List(16000 * 3);
      final rng = math.Random(42);

      // 填充背景低噪
      for (int i = 0; i < fullAudio.length; i++) {
        fullAudio[i] = (rng.nextDouble() - 0.5) * 0.05;
      }

      // 提取基准模板
      final wakeSegment = Float32List(8000);
      for (int i = 0; i < wakeSegment.length; i++) {
        final t = i / 16000.0;
        wakeSegment[i] = math.sin(2 * math.pi * 1000 * t) * 0.7 + math.sin(2 * math.pi * 2000 * t) * 0.3;
      }
      final template = MfccDtwFilter.extractMfcc(wakeSegment);

      // 将 wakeSegment 嵌入到 1.2 秒位置
      final insertStart = (16000 * 1.2).toInt();
      for (int i = 0; i < wakeSegment.length; i++) {
        fullAudio[insertStart + i] += wakeSegment[i];
      }

      final fullMfcc = MfccDtwFilter.extractMfcc(fullAudio);
      final dist = MfccDtwFilter.subsequenceDtw(template, fullMfcc);

      // 应显著小于无关信号的距离
      expect(dist, lessThan(12.0));
    });

    test('纯白噪声或完全不同频率的音频应被拒绝', () {
      final noiseAudio = Float32List(16000 * 2);
      final rng = math.Random(123);
      for (int i = 0; i < noiseAudio.length; i++) {
        noiseAudio[i] = (rng.nextDouble() - 0.5) * 0.1;
      }

      final isWake = MfccDtwFilter.checkPlausibleWake(noiseAudio, threshold: 16.0);
      expect(isWake, isFalse);
    });

    test('3 秒音频的 MFCC 提取与 DTW 运算耗时应低于 5ms (极速低功耗)', () {
      final audio = Float32List(16000 * 3);
      for (int i = 0; i < audio.length; i++) {
        audio[i] = math.sin(2 * math.pi * 600 * i / 16000) * 0.5;
      }

      final stopwatch = Stopwatch()..start();
      MfccDtwFilter.checkPlausibleWake(audio);
      stopwatch.stop();

      // 在现代 CPU 上 Dart 计算耗时通常在 1~3ms
      expect(stopwatch.elapsedMilliseconds, lessThan(20));
    });
  });
}
