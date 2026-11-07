import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// speaker_verification_service.dart 会 export speaker_audio_processor.dart，
// 与仓库内既有声纹测试保持一致，只保留这一个入口。
import 'package:side_assistant/services/speech/speaker_verification_service.dart';

/// 蓝牙 HFP/CVSD 窄带链路（8kHz 采集 → PipeWire 上采样 16kHz）的门禁回归测试。
///
/// 背景：233 上实测有效带宽仅 300~1000Hz、SCO 零空洞 21.4%，
/// 旧版绝对能量门限会把低电平真人语音判成「时长不够」。
/// 这些用例锁定「仅对有 SCO 丢包指纹的音频放宽」这一边界，
/// 保证普通麦克风与稳态噪声的拦截行为不被削弱。
void main() {
  const sampleRate = 16000;

  /// 模拟窄带浊音：仅保留基频与低阶谐波（高频共振峰已被 HFP 链路砍掉），
  /// 带 4Hz 音节包络调制。[zeroGap] 为每 683 采样点注入的数字零空洞长度。
  Float32List narrowbandSpeech(
    double seconds,
    double amp, {
    int zeroGap = 0,
  }) {
    final len = (seconds * sampleRate).round();
    final out = Float32List(len);
    for (int i = 0; i < len; i++) {
      final t = i / sampleRate;
      final env = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(2 * math.pi * 4.0 * t));
      final harmonic = 0.50 * math.sin(2 * math.pi * 140.0 * t) +
          0.30 * math.sin(2 * math.pi * 280.0 * t) +
          0.25 * math.sin(2 * math.pi * 840.0 * t);
      out[i] = amp * env * harmonic;
    }
    if (zeroGap > 0) {
      for (int s = 0; s + zeroGap < len; s += 683) {
        for (int k = 0; k < zeroGap; k++) {
          out[s + k] = 0.0;
        }
      }
    }
    return out;
  }

  Float32List narrowbandNoise(double seconds, double amp, {int zeroGap = 0}) {
    final rnd = math.Random(29);
    final len = (seconds * sampleRate).round();
    final out = Float32List.fromList(
      List.generate(len, (_) => (rnd.nextDouble() * 2 - 1) * amp),
    );
    if (zeroGap > 0) {
      for (int s = 0; s + zeroGap < len; s += 683) {
        for (int k = 0; k < zeroGap; k++) {
          out[s + k] = 0.0;
        }
      }
    }
    return out;
  }

  group('蓝牙窄带门禁自适应 - 边界与可观测性', () {
    test('无 SCO 丢包时低电平语音仍按原绝对能量门限拒绝', () {
      final outcome = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandSpeech(2, 0.015),
      );
      final diag = outcome.diagnostic;
      expect(diag.bluetoothNarrowband, isFalse);
      expect(diag.metrics['dropout']!, lessThan(0.05));
      expect(diag.metrics['peak']!, lessThan(5.0e-5));
      expect(diag.stage, 'G1-绝对能量不足');
      expect(outcome.samples, isEmpty);
    });

    test('有 SCO 丢包时同等低电平窄带语音可通过并裁出人声', () {
      final outcome = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandSpeech(2, 0.015, zeroGap: 100),
      );
      final diag = outcome.diagnostic;
      expect(diag.bluetoothNarrowband, isTrue,
          reason: '14.7% 零空洞应被识别为蓝牙 SCO 链路');
      expect(diag.metrics['dropout']!, greaterThan(0.05));
      expect(diag.stage, 'PASS', reason: '实际: ${diag.stage} ${diag.summary}');
      expect(outcome.samples.length / sampleRate, greaterThan(0.30));
    });

    test('窄带链路下低电平白噪声不得被放宽放行', () {
      final outcome = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandNoise(2, 0.015, zeroGap: 100),
      );
      expect(outcome.diagnostic.bluetoothNarrowband, isTrue);
      expect(outcome.diagnostic.isPass, isFalse,
          reason: '稳态白噪声无音节调制/无基音周期性，必须被拦');
      expect(outcome.samples, isEmpty);
    });

    test('诊断可区分输入为空、帧长不足与绝对能量不足', () {
      expect(
        SpeakerAudioProcessor.trimToSpeechDetailed(Float32List(0))
            .diagnostic
            .stage,
        'G0-输入为空',
      );
      expect(
        SpeakerAudioProcessor.trimToSpeechDetailed(Float32List(100))
            .diagnostic
            .stage,
        'G0-帧长不足',
      );
      final lowEnergy = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandSpeech(2, 0.015),
      ).diagnostic;
      expect(lowEnergy.summary, contains('peak='));
      expect(lowEnergy.summary, contains('minPeak='));
    });

    test('SCO 丢包告警阈值覆盖 21% 的实测劣化链路', () {
      expect(SpeakerAudioProcessor.dropoutWarningThreshold,
          lessThanOrEqualTo(0.20));
      final heavilyChopped = narrowbandSpeech(2, 0.015, zeroGap: 150);
      expect(
        SpeakerAudioProcessor.dropoutRatio(heavilyChopped),
        greaterThanOrEqualTo(SpeakerAudioProcessor.dropoutWarningThreshold),
        reason: '233 实测 21.4% 丢包曾因 30% 旧阈值而全天静默无告警',
      );
    });

    test('设备已判定为蓝牙时，低丢包低电平语音也走自适应路径', () {
      // 233 实测 SCO 零空洞会在 0.4%~42% 间波动；丢包率低时不能再依赖指纹。
      final signal = narrowbandSpeech(2, 0.015, zeroGap: 8);
      final byFingerprint =
          SpeakerAudioProcessor.trimToSpeechDetailed(signal).diagnostic;
      expect(byFingerprint.metrics['dropout']!, lessThan(0.05));
      expect(byFingerprint.bluetoothNarrowband, isFalse);
      expect(byFingerprint.stage, 'G1-绝对能量不足');

      final forced = SpeakerAudioProcessor.trimToSpeechDetailed(
        signal,
        forceNarrowband: true,
      ).diagnostic;
      expect(forced.bluetoothNarrowband, isTrue);
      expect(forced.stage, 'PASS',
          reason: '实际: ${forced.stage} ${forced.summary}');
    });

    test('调到最低能量阈值 1e-5 时：窄带语音通过、白噪声仍被拦', () {
      const lowest = 1.0e-5;
      final speech = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandSpeech(2, 0.015, zeroGap: 100),
        customEnergyThreshold: lowest,
      );
      expect(speech.diagnostic.stage, 'PASS',
          reason:
              '实际: ${speech.diagnostic.stage} ${speech.diagnostic.summary}');

      final noise = SpeakerAudioProcessor.trimToSpeechDetailed(
        narrowbandNoise(2, 0.015, zeroGap: 100),
        customEnergyThreshold: lowest,
      );
      expect(noise.diagnostic.isPass, isFalse,
          reason: '233 上把 speakerEnergyThreshold 降到 1e-5 后不得误放行噪声');
      expect(noise.diagnostic.stage, 'G2-稳态噪声',
          reason: '实际: ${noise.diagnostic.stage} ${noise.diagnostic.summary}');
    });

    test('静态门面 trimToSpeech 与 detailed 结果保持一致', () {
      final signal = narrowbandSpeech(2, 0.015, zeroGap: 100);
      final viaFacade = SpeakerVerificationService.trimToSpeech(signal);
      final viaDetailed =
          SpeakerAudioProcessor.trimToSpeechDetailed(signal).samples;
      expect(viaFacade.length, equals(viaDetailed.length));
      expect(viaFacade, isNotEmpty);
    });
  });
}
