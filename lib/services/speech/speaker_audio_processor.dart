import 'dart:math' as math;

import '../../core/constants/app_constants.dart';
import '../../core/platform/foundation_bridge.dart';

/// 声纹音频信号预处理与人声活跃切片处理器
///
/// 包含：
/// 1. 动态增益规整（RMS + 峰值防削顶）；
/// 2. 80Hz 一阶高通滤波（剥离低频直流偏置与环境闷音）；
/// 3. 蓝牙 SCO/HFP 链路周期性丢包空洞补偿 (PLC)；
/// 4. 基于基音周期自相关 (Voicing) 与短时能量的人声切片 (trimToSpeech)；
/// 5. 丢包率统计与告警。
class SpeakerAudioProcessor {
  /// 默认最低有效语音时长（秒）与采样点数
  static const double defaultMinSpeechSeconds = 0.30;
  static const int defaultMinAudioSamples = 4800;

  /// 对输入波形做动态增益规整（RMS + 峰值防削顶保护），消除音量增益、距离与设备响度差异
  static Float32List normalizeWaveform(Float32List samples) {
    if (samples.isEmpty) return samples;

    double maxPeak = 0.0;
    double sumSq = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final absVal = samples[i].abs();
      if (absVal > maxPeak) maxPeak = absVal;
      sumSq += absVal * absVal;
    }

    // 若音频极弱（几乎纯零或底噪），不盲目放大底噪
    if (maxPeak < 1e-4) return samples;

    // 目标 RMS 设为标准语音电平约 -20 dBFS (0.08)
    final rms = math.sqrt(sumSq / samples.length);
    double scale = 1.0;
    if (rms > 1e-4) {
      scale = 0.08 / rms;
    }
    // 限制最大增益放大倍数（最多放大 12 倍 ≈ +21.5dB），防止把微弱底噪暴力拉升至人声电平
    if (scale > 12.0) {
      scale = 12.0;
    }
    // 峰值防削顶保护：确保缩放后最大绝对值不超过 0.95
    if (maxPeak * scale > 0.95) {
      scale = 0.95 / maxPeak;
    }

    final normalized = Float32List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      normalized[i] = (samples[i] * scale).clamp(-1.0, 1.0);
    }
    return normalized;
  }

  /// 一阶 80Hz 高通滤波：滤除直流偏置 (DC offset)、50/60Hz 电源工频交流声以及 <80Hz 桌面/房间低频轰鸣，
  /// 避免低频环境闷音主导短时能量计算或侵占动态增益范围（人声基频 F0 均在 80Hz 以上）。
  static Float32List highPass80Hz(
    Float32List samples, {
    int sampleRate = 16000,
  }) {
    if (samples.isEmpty || sampleRate <= 0) return samples;
    const rc = 1.0 / (2.0 * math.pi * 80.0);
    final dt = 1.0 / sampleRate;
    final alpha = rc / (rc + dt);
    final out = Float32List(samples.length);
    double prevIn = samples[0];
    double prevOut = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final x = samples[i];
      final y = alpha * (prevOut + x - prevIn);
      out[i] = y.clamp(-1.0, 1.0);
      prevIn = x;
      prevOut = y;
    }
    return out;
  }

  /// 修复蓝牙 HFP/SCO (mSBC/CVSD) 链路丢包或 PipeWire 周期性欠载导致的短时数字零空洞（Packet Loss Concealment, PLC）。
  ///
  /// 某些 Linux 蓝牙控制器（如 Broadcom BCM20702 在 mSBC 模式下出现 `sbc_decode failed: -3`）或
  /// PipeWire `sco-io` 节点在 42.67ms (683 samples @ 16kHz) 量子周期内仅输出 240~360 个有效采样点，
  /// 其余 200~440 个采样点被填充为纯数字 0.0（形成 23.4Hz 周期性方波斩波）。
  /// 该斩波不仅会导致 Fbank 产生周期性 -15.94 底噪断崖而严重破坏 CAM++ 声纹特征（造成异人同分、本人低分），
  /// 还会打断基音自相关周期导致有效人声被误判为 <0.6s。
  ///
  /// 本方法仅在检测到音频内存在多处（>=2 处）1ms~36ms 的短时纯零凹陷时触发：
  /// - 若零空洞前导段具有显著声带谐波周期性（归一化自相关 >= 0.48），按最佳基音周期做相位连续延拓与余弦交叉淡入淡出；
  /// - 若前导段为清辅音或无周期底噪（自相关 < 0.48），采用反向镜像包络填充，仅消除频谱断崖而不注入虚假基音谐波。
  static Float32List concealBluetoothScoDropouts(
    Float32List samples, {
    int sampleRate = 16000,
  }) {
    if (samples.length < 128 || sampleRate <= 0) return samples;
    final minGap =
        math.max(12, (sampleRate * 0.001).round()); // ~1ms (16 samples)
    final maxGap = (sampleRate * 0.036).round(); // 36ms (576 samples @ 16kHz)
    // 兼容 PipeWire 重采样器在零空洞边缘残留的 2~5 个极微弱振铃采样点 (|x| <= 1.6e-4)
    const zeroEps = 1.6e-4;

    int shortGapCount = 0;
    int idx = 0;
    while (idx < samples.length) {
      if (samples[idx].abs() <= zeroEps) {
        int end = idx + 1;
        while (end < samples.length && samples[end].abs() <= zeroEps) {
          end++;
        }
        final len = end - idx;
        if (len >= minGap &&
            len <= maxGap &&
            idx >= 48 &&
            end < samples.length) {
          shortGapCount++;
        }
        idx = end;
      } else {
        idx++;
      }
    }
    // 普通麦克风或正常语音不会出现多处短时数字零空洞，直接零开销原样返回
    if (shortGapCount < 2) return samples;

    final out = Float32List.fromList(samples);
    final minLag = math.max(20, (sampleRate / 400.0).round()); // 40 @ 16kHz
    final maxLag =
        math.max(minLag + 10, (sampleRate / 75.0).round()); // 213 @ 16kHz

    int i = 0;
    while (i < out.length) {
      if (out[i].abs() <= zeroEps) {
        int j = i + 1;
        while (j < out.length && out[j].abs() <= zeroEps) {
          j++;
        }
        final zeroLen = j - i;
        if (zeroLen >= minGap &&
            zeroLen <= maxGap &&
            i >= 48 &&
            j < out.length) {
          // 吞并空洞两侧可能受重采样冲击响应污染的 2 个边缘采样点
          final start = math.max(48, i - 2);
          final end = math.min(out.length, j + 2);
          final fillLen = end - start;

          int copyPeriod = math.min(start, (sampleRate * 0.008).round());
          double bestNormCorr = 0.0;
          if (start >= maxLag + 64) {
            for (int lag = minLag; lag <= maxLag; lag += 2) {
              double c = 0.0;
              double e0 = 0.0;
              double eLag = 0.0;
              for (int k = 0; k < 64; k++) {
                final a = out[start - 1 - k];
                final b = out[start - 1 - lag - k];
                c += a * b;
                e0 += a * a;
                eLag += b * b;
              }
              final denom = math.sqrt(e0 * eLag);
              if (denom > 1e-9) {
                final norm = c / denom;
                if (norm > bestNormCorr) {
                  bestNormCorr = norm;
                  copyPeriod = lag;
                }
              }
            }
          }

          if (bestNormCorr >= 0.48) {
            for (int k = 0; k < fillLen; k++) {
              out[start + k] =
                  out[start - copyPeriod + (k % copyPeriod)] * 0.94;
            }
            if (end < out.length) {
              final fade = math.min(16, out.length - end);
              for (int f = 0; f < fade; f++) {
                final w = f / fade;
                final prev = out[start + ((fillLen + f) % copyPeriod)] * 0.94;
                out[end + f] = prev * (1.0 - w) + out[end + f] * w;
              }
            }
          } else {
            // 非浊音/环境底噪段：采用反向镜像衰减填充，保持能量连续但不引入任何 [75Hz, 400Hz] 周期谐波
            final span = math.min(start, 240);
            for (int k = 0; k < fillLen; k++) {
              final srcIdx = start - 1 - (k % span);
              out[start + k] = out[srcIdx] * 0.85;
            }
          }
        }
        i = j;
      } else {
        i++;
      }
    }
    return out;
  }

  /// 计算单帧在人类基音频率范围 [75Hz, 400Hz] 内的无偏重叠归一化自相关峰值（衡量声带周期性谐波强度）。
  /// 真实人声元音/浊辅音具有显著声带谐波周期性（通常 > 0.45），而蓝牙底噪、远场混响闷音、白噪声则较低。
  static double framePitchVoicing(
    Float32List samples,
    int start,
    int length,
    int sampleRate,
  ) {
    final minLag = math.max(1, (sampleRate / 400.0).round());
    final maxLag = math.min(length - 32, (sampleRate / 75.0).round());
    if (maxLag <= minLag) return 0.0;

    double maxNormR = 0.0;
    int bestLag = minLag;
    for (int lag = minLag; lag <= maxLag; lag += 2) {
      double r = 0.0;
      double e0 = 0.0;
      double eLag = 0.0;
      final limit = length - lag;
      for (int i = 0; i < limit; i++) {
        final a = samples[start + i];
        final b = samples[start + i + lag];
        r += a * b;
        e0 += a * a;
        eLag += b * b;
      }
      final denom = math.sqrt(e0 * eLag);
      if (denom > 1e-9) {
        final norm = r / denom;
        if (norm > maxNormR) {
          maxNormR = norm;
          bestLag = lag;
        }
      }
    }
    for (final lag in [bestLag - 1, bestLag + 1]) {
      if (lag >= minLag && lag <= maxLag) {
        double r = 0.0;
        double e0 = 0.0;
        double eLag = 0.0;
        final limit = length - lag;
        for (int i = 0; i < limit; i++) {
          final a = samples[start + i];
          final b = samples[start + i + lag];
          r += a * b;
          e0 += a * a;
          eLag += b * b;
        }
        final denom = math.sqrt(e0 * eLag);
        if (denom > 1e-9) {
          final norm = r / denom;
          if (norm > maxNormR) maxNormR = norm;
        }
      }
    }
    return maxNormR.clamp(0.0, 1.0);
  }

  /// 基于短时能量、声带基音谐波周期性 (Voicing) 与高频共振峰特性的活跃人声抽取：
  /// 1. 先修复蓝牙 SCO 周期性丢包零空洞 (PLC)，并做 80Hz 高通滤波剥离直流偏置与低频闷音；
  /// 2. 排除蓝牙硬件静音门 (Squelch Gate) 产生的纯零帧后再统计真实环境底噪分位数，
  ///    防止蓝牙静音门导致 p10/p20 归零而放行微弱环境杂音；
  /// 3. 校验活跃帧的声带周期性谐波占比（Voicing）与预加重中高频能量比，拦截无字闷音与稳态噪声；
  /// 4. 拼接所有有效人声子段（桥接 ≤180ms 的词间停顿，剔除 >180ms 的静音/底噪间隙）。
  ///
  /// 返回空数组表示没有检测到足够长的清晰人声。
  static Float32List trimToSpeech(
    Float32List samples, {
    int sampleRate = 16000,
    double minSeconds = defaultMinSpeechSeconds,
    double? customEnergyThreshold,
  }) {
    if (samples.isEmpty) return samples;
    final frame = (sampleRate * 0.025).round();
    final hop = (sampleRate * 0.010).round();
    if (frame <= 0 || hop <= 0 || samples.length < frame) return Float32List(0);

    final repaired =
        concealBluetoothScoDropouts(samples, sampleRate: sampleRate);
    final hpSamples = highPass80Hz(repaired, sampleRate: sampleRate);
    final frameCount = ((hpSamples.length - frame) ~/ hop) + 1;
    final energies = Float64List(frameCount);
    final ungated = <double>[];
    for (int f = 0; f < frameCount; f++) {
      final start = f * hop;
      double sum = 0.0;
      for (int i = start; i < start + frame; i++) {
        final v = hpSamples[i];
        sum += v * v;
      }
      final e = sum / frame;
      energies[f] = e;
      // 排除蓝牙硬件静音门关闭时的数字零帧/极微弱帧 (RMS < 0.0014)，仅对真实开启拾音的帧统计底噪
      if (e >= 2.0e-6) {
        ungated.add(e);
      }
    }
    if (ungated.isEmpty) return Float32List(0);

    ungated.sort();
    double percentileUngated(double p) => ungated[
        ((ungated.length - 1) * p).round().clamp(0, ungated.length - 1)];

    final sortedAll = Float64List.fromList(energies)..sort();
    double percentileAll(double p) => sortedAll[
        ((sortedAll.length - 1) * p).round().clamp(0, sortedAll.length - 1)];

    final p10 = percentileUngated(0.10);
    final noiseFloor = percentileUngated(0.20);
    final peak = math.max(percentileAll(0.95), percentileUngated(0.90));

    final minPeak =
        (customEnergyThreshold ?? AppConstants.defaultSpeakerEnergyThreshold)
            .clamp(1.0e-5, 2.5e-4);

    // 1. 绝对能量下限：80Hz 高通后 95%分位帧能量需达到起振门限（支持远场/近场可配，排除微弱底噪）
    if (peak < minPeak) {
      return Float32List(0);
    }

    // 2. 排除平稳背景噪声（白噪声、风扇/空调声、持续底噪）：
    // 当窗口内绝大多数帧（>75%）均为非零底噪时，若峰值与底噪比值过小（包络平坦无调制），直接判为稳态噪声。
    // 若窗口中存在明显静音段或蓝牙硬件静音门零帧（ungated <= 75%），则交由第 7 步的基音谐波周期性 (Voicing) 鉴别。
    final bool mostlyContinuous = ungated.length > (frameCount * 0.75).round();
    if (mostlyContinuous && peak < noiseFloor * 6.0 && peak < p10 * 8.5) {
      return Float32List(0);
    }

    // 3. 计算有效人声帧门限：
    // 要求单帧能量满足绝对下限（按峰值门限 35% 联动，且保底 1.5e-5）且达到峰值 8%，
    // 严防蓝牙静音门刚打开时的低电平环境尾音被划入活跃人声段。
    final double minFrameFloor = math.max(1.5e-5, minPeak * 0.35);
    final double baseFloor = !mostlyContinuous
        ? peak * 0.08
        : ((noiseFloor > peak * 0.04)
            ? math.max(p10 * 3.0, peak * 0.08)
            : math.max(noiseFloor * 5.0, peak * 0.08));
    final double effective = math.max(minFrameFloor, baseFloor);

    // 4. 标记活跃语音帧（要求至少连续 3 帧高于门限才构成语音核，滤除单帧脉冲咔哒声），
    //    并对语音核前后做 50ms (5帧) 膨胀平滑，保留词首辅音与词尾收音。
    final active = List<bool>.filled(frameCount, false);
    final padFrames = math.max(1, (0.05 * sampleRate / hop).round());
    int run = 0;
    for (int f = 0; f < frameCount; f++) {
      if (energies[f] >= effective) {
        run++;
        if (run >= 3) {
          final coreStart = f - run + 1;
          final s = math.max(0, coreStart - padFrames);
          final e = math.min(frameCount - 1, f + padFrames);
          for (int k = s; k <= e; k++) {
            active[k] = true;
          }
        }
      } else {
        run = 0;
      }
    }

    // 5. 桥接短于 180ms (18帧) 的词间正常停顿，超过 180ms 的静音/环境噪声段直接剔除不拼接
    final maxBridgeGap = math.max(1, (0.18 * sampleRate / hop).round());
    int lastTrue = -1;
    for (int f = 0; f < frameCount; f++) {
      if (active[f]) {
        if (lastTrue >= 0 && (f - lastTrue) <= maxBridgeGap) {
          for (int k = lastTrue + 1; k < f; k++) {
            active[k] = true;
          }
        }
        lastTrue = f;
      }
    }

    // 6. 收集所有连续的活跃语音子段（剔除短于 180ms 的孤立短杂音）
    final minSegSec = math.min(0.18, minSeconds * 0.75);
    final minSegmentFrames =
        math.max(3, (minSegSec * sampleRate / hop).round());
    final segments = <(int, int)>[];
    int segStart = -1;
    for (int f = 0; f < frameCount; f++) {
      if (active[f]) {
        if (segStart < 0) segStart = f;
      } else if (segStart >= 0) {
        if (f - segStart >= minSegmentFrames) {
          segments.add((segStart, f - 1));
        }
        segStart = -1;
      }
    }
    if (segStart >= 0 && (frameCount - segStart) >= minSegmentFrames) {
      segments.add((segStart, frameCount - 1));
    }
    if (segments.isEmpty) return Float32List(0);

    // 7. 声带谐波周期性 (Voicing) 与共振峰高频能量比校验：
    // 防止远场低频混响闷音、关门/碰撞声或非人声杂音通过能量门限后污染声纹池化层。
    int coreFrames = 0;
    int voicedFrames = 0;
    double preempEnergy = 0.0;
    double rawActiveEnergy = 0.0;
    for (final seg in segments) {
      for (int f = seg.$1; f <= seg.$2; f++) {
        if (energies[f] >= effective) {
          coreFrames++;
          final start = f * hop;
          if (framePitchVoicing(hpSamples, start, frame, sampleRate) >= 0.45) {
            voicedFrames++;
          }
          for (int i = start + 1; i < start + frame; i++) {
            final d = hpSamples[i] - 0.97 * hpSamples[i - 1];
            preempEnergy += d * d;
            rawActiveEnergy += hpSamples[i] * hpSamples[i];
          }
        }
      }
    }

    final coreSec = coreFrames * (hop / sampleRate);
    final voicedSec = voicedFrames * (hop / sampleRate);
    final voicedRatio = coreFrames > 0 ? voicedFrames / coreFrames : 0.0;
    final preempRatio =
        rawActiveEnergy > 0 ? math.sqrt(preempEnergy / rawActiveEnergy) : 0.0;

    if (coreSec < math.min(0.32, minSeconds * 0.45) ||
        voicedSec < math.min(0.16, minSeconds * 0.35) ||
        voicedRatio < 0.25 ||
        preempRatio < 0.18) {
      return Float32List(0);
    }

    // 8. 拼接所有有效语音子段，彻底剥离中间静音与背景底噪
    int totalSamples = 0;
    final sampleRanges = <(int, int)>[];
    for (final seg in segments) {
      final startSample = (seg.$1 * hop).clamp(0, hpSamples.length);
      final endSample = math.min(hpSamples.length, seg.$2 * hop + frame);
      if (endSample > startSample) {
        sampleRanges.add((startSample, endSample));
        totalSamples += (endSample - startSample);
      }
    }

    final minSamples = (minSeconds * sampleRate).round();
    if (totalSamples < minSamples) return Float32List(0);

    if (sampleRanges.length == 1) {
      final r = sampleRanges.first;
      return hpSamples.sublist(r.$1, r.$2);
    }

    final out = Float32List(totalSamples);
    int offset = 0;
    for (final r in sampleRanges) {
      final len = r.$2 - r.$1;
      out.setRange(offset, offset + len, hpSamples, r.$1);
      offset += len;
    }
    return out;
  }

  /// 统计音频中被“短时数字零空洞”（1ms~36ms 连续纯零）占据的采样点比例。
  ///
  /// 正常麦克风此值接近 0；蓝牙 HFP/mSBC 解码失败（`sbc_decode failed: -3`）时
  /// 可达 40%~50%。这类斩波会让不同说话人的声纹向量被拉近（实测跨说话人相似度
  /// 由 0.19 升至 0.45，最高 0.68），电视人声因此容易被误判为主人。
  static double dropoutRatio(Float32List samples, {int sampleRate = 16000}) {
    if (samples.length < 128) return 0.0;
    final minGap = math.max(12, (sampleRate * 0.001).round());
    final maxGap = (sampleRate * 0.036).round();
    const zeroEps = 1.6e-4;
    int inGaps = 0;
    int i = 0;
    while (i < samples.length) {
      if (samples[i].abs() <= zeroEps) {
        int j = i + 1;
        while (j < samples.length && samples[j].abs() <= zeroEps) {
          j++;
        }
        final len = j - i;
        if (len >= minGap && len <= maxGap) inGaps += len;
        i = j;
      } else {
        i++;
      }
    }
    return inGaps / samples.length;
  }

  /// 丢包比例过高时给出明确告警，便于定位“同分/异人高分”类问题。
  static void warnIfDropouts(Float32List samples, String stage) {
    final ratio = dropoutRatio(samples);
    if (ratio >= 0.30) {
      debugPrint(
        '[SpeakerVerificationService] ⚠️ $stage音频存在严重丢包：'
        '${(ratio * 100).toStringAsFixed(0)}% 采样点为数字零空洞，'
        '声纹结果不可信（检查蓝牙是否处于 mSBC 模式，建议改用 CVSD 或有线麦克风）',
      );
    }
  }
}
