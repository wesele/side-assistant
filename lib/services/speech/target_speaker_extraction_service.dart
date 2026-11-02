import 'dart:math' as math;

import '../../core/models/app_settings.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/ports/target_speaker_extraction_port.dart';
import 'speaker_verification_service.dart';

/// 目标说话人语音抽取结果元数据
class TargetSpeakerExtractionResult {
  /// 抽取/净化后的纯净音频（16kHz PCM Float32List）
  final Float32List extractedSamples;

  /// 是否真正执行了抽取（未开启开关或未注册声纹时为 false）
  final bool isExtracted;

  /// 全程目标说话人平均置信度（0.0 ~ 1.0）
  final double averageTargetConfidence;

  /// 被判定为非目标说话人（电视/路人/其他声音）并被抑制的时长比例（0.0 ~ 1.0）
  final double suppressedRatio;

  /// 抽取计算耗时（毫秒）
  final int durationMs;

  const TargetSpeakerExtractionResult({
    required this.extractedSamples,
    required this.isExtracted,
    required this.averageTargetConfidence,
    required this.suppressedRatio,
    required this.durationMs,
  });

  factory TargetSpeakerExtractionResult.passthrough(Float32List samples) =>
      TargetSpeakerExtractionResult(
        extractedSamples: samples,
        isExtracted: false,
        averageTargetConfidence: 1.0,
        suppressedRatio: 0.0,
        durationMs: 0,
      );
}

/// 方案二：目标说话人语音抽取服务（Target Speaker Extraction, TSE）
///
/// 核心功能：
/// 将主人预注册的声纹（Embedding）作为空间/声学先验线索，
/// 从麦克风采集的混合音频中精准分离出主人的纯净人声，
/// 并对背景电视声（影视台词/新闻播报）、户外路人闲聊、环境突发人声进行深度衰减与滤除（10dB ~ 30dB），
/// 确保喂给 ASR 识别引擎的只有主人所说的内容。
class TargetSpeakerExtractionService implements TargetSpeakerExtractionPort {
  final AppSettings settings;
  final SpeakerVerificationService speakerVerificationService;

  static const int sampleRate = 16000;

  // 滑动声纹探针参数
  static const int _subWindowSamples = 16000; // 1.0 秒短窗（保证 CAM++ 特征稳定且具备充裕语调信息）
  static const int _subHopSamples = 4000;     // 0.25 秒步长（4 Hz 时间分辨率）

  // STFT 时频掩蔽与重构参数
  static const int _fftSize = 512;
  static const int _frameLength = 400; // 25ms @ 16kHz
  static const int _frameStep = 160;   // 10ms @ 16kHz

  // 预计算 Hann 加窗与正余弦查找表
  static final Float64List _hannWindow = _initHannWindow();

  TargetSpeakerExtractionService({
    required this.settings,
    required this.speakerVerificationService,
  });

  bool get isReady => speakerVerificationService.isReady;
  @override
  bool get hasEnrolledOwner => speakerVerificationService.hasEnrolledOwner;

  static Float64List _initHannWindow() {
    final win = Float64List(_frameLength);
    for (int i = 0; i < _frameLength; i++) {
      win[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (_frameLength - 1)));
    }
    return win;
  }

  /// 目标说话人语音抽取：直接返回净化后的 PCM Float32List
  @override
  Float32List extractTargetSpeaker(
    Float32List mixedSamples, {
    int sampleRate = 16000,
  }) {
    return extractTargetSpeakerWithMetrics(mixedSamples, sampleRate: sampleRate)
        .extractedSamples;
  }

  /// 目标说话人语音抽取（含详细分析指标）
  TargetSpeakerExtractionResult extractTargetSpeakerWithMetrics(
    Float32List mixedSamples, {
    int sampleRate = 16000,
  }) {
    // 1. 开关检查与前置条件
    if (!settings.enableTargetSpeakerExtraction ||
        !speakerVerificationService.hasEnrolledOwner ||
        mixedSamples.isEmpty) {
      return TargetSpeakerExtractionResult.passthrough(mixedSamples);
    }

    // 2. 若声纹模型未初始化，尝试拉起；若仍未就绪则直接放行
    if (!speakerVerificationService.isReady) {
      return TargetSpeakerExtractionResult.passthrough(mixedSamples);
    }

    final sw = Stopwatch()..start();
    final n = mixedSamples.length;

    // 3. 极短音频片段处理（小于 0.3 秒，声纹难以分辨，直接原样放行）
    if (n < 4800) {
      sw.stop();
      return TargetSpeakerExtractionResult(
        extractedSamples: mixedSamples,
        isExtracted: false,
        averageTargetConfidence: 1.0,
        suppressedRatio: 0.0,
        durationMs: sw.elapsedMilliseconds,
      );
    }

    // 修复蓝牙 SCO 链路可能存在的周期性短时数字零空洞，避免 STFT 与滑动窗口特征失真
    mixedSamples = SpeakerVerificationService.concealBluetoothScoDropouts(
      mixedSamples,
      sampleRate: sampleRate,
    );

    final threshold = settings.tseSimilarityThreshold;
    final attenuationDb = settings.tseAttenuationDb;
    final minGain = math.pow(10.0, -attenuationDb / 20.0).toDouble().clamp(0.01, 0.5);

    // 4. 若音频在 0.3s ~ 0.6s 之间，单窗填充评估
    if (n < _subWindowSamples) {
      final padded = Float32List(_subWindowSamples);
      padded.setRange(0, n, mixedSamples);
      // 循环填充达到最小抽取长度
      for (int i = n; i < _subWindowSamples; i++) {
        padded[i] = mixedSamples[i % n];
      }

      final emb = speakerVerificationService.extractEmbedding(padded, sampleRate: sampleRate);
      double sim = 0.0;
      if (emb != null) {
        sim = speakerVerificationService.computeMaxSimilarity(emb.map((e) => e.toDouble()).toList());
      }

      sw.stop();
      // 短音频（如唤醒词、简短确认）因音素特征有限，相似度普遍偏低，采用宽容阈值防误杀
      final shortAudioThreshold = (threshold - 0.08).clamp(0.40, 0.65);
      if (sim >= shortAudioThreshold) {
        // 匹配主人声纹，完全保留
        return TargetSpeakerExtractionResult(
          extractedSamples: mixedSamples,
          isExtracted: true,
          averageTargetConfidence: sim,
          suppressedRatio: 0.0,
          durationMs: sw.elapsedMilliseconds,
        );
      } else {
        // 确实远低于主人声纹阈值时才进行静音抑制
        return TargetSpeakerExtractionResult(
          extractedSamples: Float32List(n),
          isExtracted: true,
          averageTargetConfidence: sim,
          suppressedRatio: 1.0,
          durationMs: sw.elapsedMilliseconds,
        );
      }
    }

    // 5. 音频 >= 1.0 秒：滑动窗口声纹追踪与连续置信度轨迹生成
    // 全局快速初筛：若整段音频的主人相似度极低，判定为纯电视/纯路人闲聊，直接全段静音置零
    if (n >= _subWindowSamples) {
      final rawGlobal = n > 48000 ? mixedSamples.sublist(0, 48000) : mixedSamples;
      final trimmedGlobal = SpeakerVerificationService.trimToSpeech(
        rawGlobal,
        sampleRate: sampleRate,
      );
      final sampleForGlobal =
          trimmedGlobal.length >= speakerVerificationService.minAudioSamples
              ? trimmedGlobal
              : rawGlobal;
      final globalEmb = speakerVerificationService.extractEmbedding(
        sampleForGlobal,
        sampleRate: sampleRate,
      );
      if (globalEmb != null) {
        final globalSim = speakerVerificationService.computeMaxSimilarity(
          globalEmb.map((e) => e.toDouble()).toList(),
        );
        if (globalSim < threshold - 0.15) {
          sw.stop();
          debugPrint(
            '[TargetSpeakerExtraction] 全局初筛未检测到主人声纹 (全局相似度 ${(globalSim * 100).toStringAsFixed(1)}% < ${((threshold - 0.15) * 100).toInt()}%)，'
            '已静音丢弃电视/路人杂音',
          );
          return TargetSpeakerExtractionResult(
            extractedSamples: Float32List(n),
            isExtracted: true,
            averageTargetConfidence: globalSim,
            suppressedRatio: 1.0,
            durationMs: sw.elapsedMilliseconds,
          );
        }
      }
    }

    final numWindows = math.max(1, ((n - _subWindowSamples) ~/ _subHopSamples) + 1);
    final winCenters = <int>[];
    final winSims = <double>[];

    double prevSim = threshold; // 默认平滑初始值
    double maxWinSim = 0.0;

    for (int k = 0; k < numWindows; k++) {
      final start = k * _subHopSamples;
      final slice = mixedSamples.sublist(start, start + _subWindowSamples);

      // 计算短窗 RMS 能量
      double sumSq = 0.0;
      for (int i = 0; i < slice.length; i++) {
        sumSq += slice[i] * slice[i];
      }
      final rms = math.sqrt(sumSq / slice.length);

      double sim = 0.0;
      if (rms < 0.008 && prevSim >= threshold) {
        // 短暂换气或字间静音停顿：保留上一个有效窗的置信度，避免将换气停顿误当成旁人杂音而截断字音
        sim = prevSim * 0.95;
      } else {
        final emb = speakerVerificationService.extractEmbedding(slice, sampleRate: sampleRate);
        if (emb != null) {
          sim = speakerVerificationService.computeMaxSimilarity(emb.map((e) => e.toDouble()).toList());
        }
      }

      if (rms >= 0.008) {
        prevSim = sim;
      }
      if (sim > maxWinSim) {
        maxWinSim = sim;
      }
      winCenters.add(start + _subWindowSamples ~/ 2);
      winSims.add(sim);
    }

    // 处理末尾不足一个 hop 长度的收尾窗口
    final lastStart = n - _subWindowSamples;
    if (lastStart > (numWindows - 1) * _subHopSamples + 800) {
      final slice = mixedSamples.sublist(lastStart, n);
      final emb = speakerVerificationService.extractEmbedding(slice, sampleRate: sampleRate);
      double sim = 0.0;
      if (emb != null) {
        sim = speakerVerificationService.computeMaxSimilarity(emb.map((e) => e.toDouble()).toList());
        if (sim > maxWinSim) maxWinSim = sim;
      }
      winCenters.add(lastStart + _subWindowSamples ~/ 2);
      winSims.add(sim);
    }

    // 关键拦截：若整段音频中没有任何一个窗口达到主人声纹门限，判定为纯电视/路人/其他说话人，整段静音置零丢弃
    if (maxWinSim < threshold) {
      sw.stop();
      debugPrint(
        '[TargetSpeakerExtraction] 未检测到主人声纹 (最高相似度 ${(maxWinSim * 100).toStringAsFixed(1)}% < ${(threshold * 100).toInt()}%)，'
        '已彻底静音滤除电视/路人语音 (时长 ${(n / sampleRate).toStringAsFixed(1)}s, 耗时 ${sw.elapsedMilliseconds}ms)',
      );
      return TargetSpeakerExtractionResult(
        extractedSamples: Float32List(n), // 全置零静音，下游 ASR 转写为空串并直接忽略
        isExtracted: true,
        averageTargetConfidence: maxWinSim,
        suppressedRatio: 1.0,
        durationMs: sw.elapsedMilliseconds,
      );
    }

    // 6. 生成逐采样点的平滑增益轨迹 g(t)
    final timeGain = Float64List(n);
    int centerIdx = 0;
    double totalSim = 0.0;
    int suppressedSamples = 0;

    for (int i = 0; i < n; i++) {
      while (centerIdx < winCenters.length - 1 && i > winCenters[centerIdx + 1]) {
        centerIdx++;
      }

      double sim;
      if (winCenters.length == 1) {
        sim = winSims[0];
      } else if (i <= winCenters[0]) {
        sim = winSims[0];
      } else if (i >= winCenters.last) {
        sim = winSims.last;
      } else {
        final c0 = winCenters[centerIdx];
        final c1 = winCenters[centerIdx + 1];
        final factor = (i - c0) / (c1 - c0);
        sim = (1.0 - factor) * winSims[centerIdx] + factor * winSims[centerIdx + 1];
      }

      totalSim += sim;

      // 目标说话人增益映射：
      // - 远高于阈值：增益为 1.0 (主人声音完整保留)
      // - 低于阈值：增益衰减为 0.0 或微小底噪 (消除伴随的电视/路人插话)
      final lowBound = threshold - 0.12;
      final highBound = threshold + 0.05;
      double g;
      if (sim >= highBound) {
        g = 1.0;
      } else if (sim <= lowBound) {
        g = 0.0; // 彻底消音非目标语音
        suppressedSamples++;
      } else {
        final norm = (sim - lowBound) / (highBound - lowBound);
        final smoothStep = norm * norm * (3.0 - 2.0 * norm); // Hermite smoothstep
        g = smoothStep;
        if (g < 0.5) suppressedSamples++;
      }
      timeGain[i] = g;
    }

    final avgConf = totalSim / n;
    final suppRatio = suppressedSamples / n;

    // 7. 时频域 STFT 掩蔽抽取与重构 (VoiceFilter 掩蔽范式)
    final numFrames = (n - _frameLength) ~/ _frameStep + 1;
    final output = Float32List(n);
    final winSum = Float64List(n);

    final real = Float64List(_fftSize);
    final imag = Float64List(_fftSize);

    for (int f = 0; f < numFrames; f++) {
      final start = f * _frameStep;
      final frameCenter = start + _frameLength ~/ 2;
      final frameBaseGain = timeGain[frameCenter.clamp(0, n - 1)];

      // a. 加分析窗
      for (int i = 0; i < _frameLength; i++) {
        real[i] = mixedSamples[start + i] * _hannWindow[i];
        imag[i] = 0.0;
      }
      for (int i = _frameLength; i < _fftSize; i++) {
        real[i] = 0.0;
        imag[i] = 0.0;
      }

      // b. 正向 FFT
      _fftRadix2(real, imag);

      // c. 时频掩蔽：在非目标人声/电视声区，对人声非核心频段追加低通/高通衰减
      for (int k = 0; k <= _fftSize ~/ 2; k++) {
        final freqHz = k * sampleRate / _fftSize;
        double mask = frameBaseGain;

        // 若当前帧判定为非主人（电视/路人），额外压制 <180Hz 轰鸣和 >3800Hz 背景杂音
        if (frameBaseGain < 0.85) {
          if (freqHz < 180.0 || freqHz > 3800.0) {
            mask *= minGain;
          }
        }

        // 对称频率 bin 同步应用掩蔽
        real[k] *= mask;
        imag[k] *= mask;
        if (k > 0 && k < _fftSize ~/ 2) {
          real[_fftSize - k] *= mask;
          imag[_fftSize - k] *= mask;
        }
      }

      // d. 逆向 FFT (iFFT)
      _ifftRadix2(real, imag);

      // e. 加合成窗并重叠相加 (Overlap-Add, OLA)
      for (int i = 0; i < _frameLength; i++) {
        final idx = start + i;
        final w = _hannWindow[i];
        output[idx] += (real[i] * w).toFloat();
        winSum[idx] += w * w;
      }
    }

    // 8. 窗口能量归一化（保证在增益为 1 时能量完全无损重构）
    for (int i = 0; i < n; i++) {
      final w = winSum[i];
      if (w > 1e-4) {
        output[i] = (output[i] / w).clamp(-1.0, 1.0);
      } else {
        // 边界未覆盖区域保持平滑时间增益
        output[i] = (mixedSamples[i] * timeGain[i]).clamp(-1.0, 1.0);
      }
    }

    sw.stop();
    debugPrint(
      '[TargetSpeakerExtraction] 目标说话人抽取完成: '
      '时长=${(n / sampleRate).toStringAsFixed(1)}s, '
      '主人平均置信度=${(avgConf * 100).toStringAsFixed(1)}%, '
      '干扰人声/背景抑制比=${(suppRatio * 100).toStringAsFixed(1)}%, '
      '耗时=${sw.elapsedMilliseconds}ms',
    );

    return TargetSpeakerExtractionResult(
      extractedSamples: output,
      isExtracted: true,
      averageTargetConfidence: avgConf,
      suppressedRatio: suppRatio,
      durationMs: sw.elapsedMilliseconds,
    );
  }

  /// 512 点 Cooley-Tukey Radix-2 正向快速傅里叶变换
  static void _fftRadix2(Float64List real, Float64List imag) {
    const n = _fftSize;
    int j = 0;
    for (int i = 0; i < n - 1; i++) {
      if (i < j) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
      int k = n ~/ 2;
      while (k <= j) {
        j -= k;
        k ~/= 2;
      }
      j += k;
    }

    for (int len = 2; len <= n; len <<= 1) {
      final half = len ~/ 2;
      final angle = -2.0 * math.pi / len;
      final wstepR = math.cos(angle);
      final wstepI = math.sin(angle);

      for (int i = 0; i < n; i += len) {
        double wR = 1.0;
        double wI = 0.0;
        for (int m = 0; m < half; m++) {
          final uR = real[i + m];
          final uI = imag[i + m];
          final vR = real[i + m + half] * wR - imag[i + m + half] * wI;
          final vI = real[i + m + half] * wI + imag[i + m + half] * wR;

          real[i + m] = uR + vR;
          imag[i + m] = uI + vI;
          real[i + m + half] = uR - vR;
          imag[i + m + half] = uI - vI;

          final nextWr = wR * wstepR - wI * wstepI;
          wI = wR * wstepI + wI * wstepR;
          wR = nextWr;
        }
      }
    }
  }

  /// 512 点 逆向快速傅里叶变换 (iFFT)
  static void _ifftRadix2(Float64List real, Float64List imag) {
    const n = _fftSize;
    // 利用共轭性质: iFFT(X) = (1/N) * FFT(X*)*
    for (int i = 0; i < n; i++) {
      imag[i] = -imag[i];
    }
    _fftRadix2(real, imag);
    for (int i = 0; i < n; i++) {
      real[i] /= n;
      imag[i] = -imag[i] / n;
    }
  }
}

extension _DoubleToFloat on double {
  double toFloat() => this;
}
