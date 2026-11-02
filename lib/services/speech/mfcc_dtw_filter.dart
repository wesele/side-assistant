import 'dart:math' as math;
import 'dart:typed_data';

/// 纯算法轻量级 MFCC 特征提取与子序列动态时间规整（Subsequence DTW）前置声学过滤器
/// 运行在纯 CPU/Dart 内存中，耗时 < 1ms，0 外部模型依赖。
///
/// ⚠️ 当前状态：未接入语音识别链路。
///
/// 内置的「小曼 / 晓漫」参考模板是**用正弦波合成的假语音**（见 [_synthesizeWakeMfcc]），
/// 与真人发音的共振峰轨迹差距很大，实测会把真正的唤醒词判为「不含唤醒特征」而误杀，
/// 因此已从 [LocalSenseVoiceAsrService] 的待机识别路径中移除硬门控。
///
/// 若要重新启用此低功耗预筛，必须先替换 [_initBuiltInTemplates] 为**真人录音**的
/// MFCC 模板（或改为运行时用已确认的唤醒语句自学习模板），否则会持续漏识别。
/// 保留本文件与其单元测试，便于后续接入真实模板后复用。
class MfccDtwFilter {
  static const int sampleRate = 16000;
  static const int frameLength = 400; // 25ms @ 16kHz
  static const int frameStep = 160; // 10ms step (100 fps)
  static const int numFilters = 26;
  static const int numCepstra = 13;
  static const int fftSize = 512;

  // 汉明窗表与梅尔三角滤波器组预计算缓存
  static final Float64List _hammingWindow = _initHamming();
  static final List<Float64List> _melFilters = _initMelFilters();
  static final Float64List _dctCosTable = _initDctTable();

  // 预置“小曼 / 晓漫”声学基准模板库（包含常速、快速、慢速 3 种发音形态，按需懒加载）
  static List<List<Float64List>>? _cachedTemplates;
  static List<List<Float64List>> get _referenceTemplates =>
      _cachedTemplates ??= _initBuiltInTemplates();

  // 宽松高召回判决门限（DTW 归一化平均帧间欧氏距离，真实语音通常在 26.0 - 38.0 之间）
  static const double defaultDistanceThreshold = 45.0;

  static Float64List _initHamming() {
    final win = Float64List(frameLength);
    for (int i = 0; i < frameLength; i++) {
      win[i] = 0.54 - 0.46 * math.cos(2 * math.pi * i / (frameLength - 1));
    }
    return win;
  }

  static double _hzToMel(double hz) =>
      2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
  static double _melToHz(double mel) =>
      700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

  static List<Float64List> _initMelFilters() {
    final filters = List<Float64List>.generate(
        numFilters, (_) => Float64List(fftSize ~/ 2 + 1));
    final lowMel = _hzToMel(100.0);
    final highMel = _hzToMel(7000.0);
    final melPoints = Float64List(numFilters + 2);
    final deltaMel = (highMel - lowMel) / (numFilters + 1);

    for (int i = 0; i < numFilters + 2; i++) {
      melPoints[i] = lowMel + i * deltaMel;
    }

    final binPoints = Int32List(numFilters + 2);
    for (int i = 0; i < numFilters + 2; i++) {
      final hz = _melToHz(melPoints[i]);
      binPoints[i] =
          ((fftSize + 1) * hz / sampleRate).floor().clamp(0, fftSize ~/ 2);
    }

    for (int m = 1; m <= numFilters; m++) {
      final left = binPoints[m - 1];
      final center = binPoints[m];
      final right = binPoints[m + 1];

      for (int k = left; k < center; k++) {
        if (center != left) {
          filters[m - 1][k] = (k - left) / (center - left);
        }
      }
      for (int k = center; k <= right; k++) {
        if (right != center) {
          filters[m - 1][k] = (right - k) / (right - center);
        }
      }
    }
    return filters;
  }

  static Float64List _initDctTable() {
    final table = Float64List(numCepstra * numFilters);
    for (int i = 0; i < numCepstra; i++) {
      for (int m = 0; m < numFilters; m++) {
        table[i * numFilters + m] =
            math.cos(math.pi * i * (m + 0.5) / numFilters);
      }
    }
    return table;
  }

  /// 提取 13 维 MFCC 特征矩阵（帧数 x 13）
  static List<Float64List> extractMfcc(Float32List samples) {
    if (samples.length < frameLength) return [];

    final numFrames = (samples.length - frameLength) ~/ frameStep + 1;
    final mfccFrames = <Float64List>[];

    final frameBuffer = Float64List(fftSize);
    final real = Float64List(fftSize);
    final imag = Float64List(fftSize);
    final powerSpec = Float64List(fftSize ~/ 2 + 1);

    for (int f = 0; f < numFrames; f++) {
      final start = f * frameStep;

      // 1. 预加重与加窗
      double prev =
          start > 0 ? samples[start - 1].toDouble() : samples[start].toDouble();
      for (int n = 0; n < frameLength; n++) {
        final cur = samples[start + n].toDouble();
        final preEmphasized = cur - 0.97 * prev;
        prev = cur;
        frameBuffer[n] = preEmphasized * _hammingWindow[n];
      }
      for (int n = frameLength; n < fftSize; n++) {
        frameBuffer[n] = 0.0;
      }

      // 2. 快速 512 点实数 FFT 与功率谱
      for (int i = 0; i < fftSize; i++) {
        real[i] = frameBuffer[i];
        imag[i] = 0.0;
      }
      _fftRadix2(real, imag);

      for (int k = 0; k <= fftSize ~/ 2; k++) {
        powerSpec[k] = (real[k] * real[k] + imag[k] * imag[k]) / fftSize;
      }

      // 3. 应用梅尔滤波器组并取对数
      final logMel = Float64List(numFilters);
      for (int m = 0; m < numFilters; m++) {
        double sum = 0.0;
        final filter = _melFilters[m];
        for (int k = 0; k <= fftSize ~/ 2; k++) {
          sum += powerSpec[k] * filter[k];
        }
        logMel[m] = math.log(sum > 1e-10 ? sum : 1e-10);
      }

      // 4. DCT 变换提取 13 维倒谱系数
      final cepstrum = Float64List(numCepstra);
      for (int i = 0; i < numCepstra; i++) {
        double c = 0.0;
        final offset = i * numFilters;
        for (int m = 0; m < numFilters; m++) {
          c += logMel[m] * _dctCosTable[offset + m];
        }
        cepstrum[i] = c;
      }
      mfccFrames.add(cepstrum);
    }

    // 5. 倒谱均值归一化（CMN），消除环境麦克风静态偏置
    if (mfccFrames.isNotEmpty) {
      final mean = Float64List(numCepstra);
      for (final frame in mfccFrames) {
        for (int i = 0; i < numCepstra; i++) {
          mean[i] += frame[i];
        }
      }
      for (int i = 0; i < numCepstra; i++) {
        mean[i] /= mfccFrames.length;
      }
      for (final frame in mfccFrames) {
        for (int i = 0; i < numCepstra; i++) {
          frame[i] -= mean[i];
        }
      }
    }

    return mfccFrames;
  }

  /// 512 点 Cooley-Tukey Radix-2 FFT
  static void _fftRadix2(Float64List real, Float64List imag) {
    const n = 512;
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

  /// 帧间欧氏距离
  static double _euclideanDist(Float64List a, Float64List b) {
    double sum = 0.0;
    for (int i = 0; i < numCepstra; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  /// 子序列动态时间规整（Subsequence DTW）
  /// 在参考长音频序列 R（N 帧）中搜索模板序列 Q（M 帧）的最优匹配子序列
  /// 返回归一化的最小帧平均距离
  static double subsequenceDtw(
      List<Float64List> template, List<Float64List> query) {
    final m = template.length;
    final n = query.length;
    if (m == 0 || n == 0 || n < m ~/ 2) return double.infinity;

    // dp[j] 保存上一行代价，cur[j] 保存当前行代价
    var prevRow = Float64List(n);
    var curRow = Float64List(n);

    // 第一行：允许模板起始帧与输入序列的任意位置对齐（sDTW 核心）
    for (int j = 0; j < n; j++) {
      prevRow[j] = _euclideanDist(template[0], query[j]);
    }

    for (int i = 1; i < m; i++) {
      curRow[0] = prevRow[0] + _euclideanDist(template[i], query[0]);
      for (int j = 1; j < n; j++) {
        final cost = _euclideanDist(template[i], query[j]);
        final minPrev =
            math.min(prevRow[j], math.min(curRow[j - 1], prevRow[j - 1]));
        curRow[j] = cost + minPrev;
      }
      final temp = prevRow;
      prevRow = curRow;
      curRow = temp;
    }

    // 在最后一行中寻找全局最小对齐代价
    double minCost = double.infinity;
    for (int j = 0; j < n; j++) {
      if (prevRow[j] < minCost) {
        minCost = prevRow[j];
      }
    }

    return minCost / m;
  }

  /// 综合多模板匹配输入音频是否极可能包含唤醒词“小曼/晓漫”
  static bool checkPlausibleWake(
    Float32List samples, {
    double threshold = defaultDistanceThreshold,
  }) {
    if (samples.length < frameLength * 2) return false;

    // 1. 提取当前音频 MFCC 矩阵
    final mfcc = extractMfcc(samples);
    if (mfcc.length < 15) return false;

    // 2. 依次与内置模板库匹配，寻找最小距离
    double bestDistance = double.infinity;
    for (final template in _referenceTemplates) {
      final dist = subsequenceDtw(template, mfcc);
      if (dist < bestDistance) {
        bestDistance = dist;
      }
      // 若已有模板距离显著小于阈值，快速早退
      if (bestDistance < threshold * 0.75) {
        return true;
      }
    }

    return bestDistance <= threshold;
  }

  /// 构建基准声学模板（合成“x-i-a-o-m-a-n”及“x-i-a-o-m-a-i(小麦)”典型共振峰及语速变体）
  static List<List<Float64List>> _initBuiltInTemplates() {
    return [
      _synthesizeWakeMfcc(speedFactor: 1.0), // 标准常速 xiaoman (~0.50s)
      _synthesizeWakeMfcc(speedFactor: 0.75), // 快速呼叫 xiaoman (~0.38s)
      _synthesizeWakeMfcc(speedFactor: 1.25), // 慢速拖长 xiaoman (~0.62s)
      _synthesizeWakeMfcc(
          speedFactor: 1.0, isMaiEnding: true), // 小麦 xiaomai (~0.50s)
    ];
  }

  /// 声学共振峰声学轨迹合成器（纯数学模拟 [ɕ-i̯-ɑ-ʊ] + [m-a-n] / [m-a-i] 频谱包络）
  static List<Float64List> _synthesizeWakeMfcc({
    required double speedFactor,
    bool isMaiEnding = false,
  }) {
    final baseDurationMs = 500.0 * speedFactor;
    final totalSamples = (sampleRate * (baseDurationMs / 1000.0)).toInt();
    final synth = Float32List(totalSamples);

    for (int i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final progress = i / totalSamples; // 0.0 ~ 1.0

      double sample = 0.0;
      if (progress < 0.25) {
        // [x/ɕ] 辅音擦音：高频 3500-5500Hz 湍流
        final noise = (math.sin(2 * math.pi * 4200 * t) +
                math.sin(2 * math.pi * 5100 * t)) *
            0.4;
        sample = noise * (progress / 0.25);
      } else if (progress < 0.55) {
        // [iao] 双元音：F1: 320->700Hz, F2: 2100->1150Hz
        final localP = (progress - 0.25) / 0.30;
        final f1 = 320.0 + localP * 380.0;
        final f2 = 2100.0 - localP * 950.0;
        sample = (math.sin(2 * math.pi * f1 * t) * 0.7 +
            math.sin(2 * math.pi * f2 * t) * 0.5);
      } else if (progress < 0.75) {
        // [m] 双唇鼻音：F1: 250Hz, 反共振阻尼
        sample = math.sin(2 * math.pi * 250 * t) * 0.6;
      } else {
        if (isMaiEnding) {
          // [ai] 双元音 (小麦)：F1: 750->400Hz, F2: 1200->2200Hz
          final localP = (progress - 0.75) / 0.25;
          final f1 = 750.0 - localP * 350.0;
          final f2 = 1200.0 + localP * 1000.0;
          sample = (math.sin(2 * math.pi * f1 * t) * 0.7 +
              math.sin(2 * math.pi * f2 * t) * 0.5);
        } else {
          // [an] 元音+鼻尾韵 (小曼)：F1: 750Hz, F2: 1350Hz, F3: 2500Hz
          sample = (math.sin(2 * math.pi * 750 * t) * 0.6 +
              math.sin(2 * math.pi * 1350 * t) * 0.4 +
              math.sin(2 * math.pi * 2500 * t) * 0.2);
        }
      }

      // 添加轻微基频包络 (F0 ~ 180Hz)
      final f0 = math.sin(2 * math.pi * 180 * t);
      synth[i] = (sample * 0.7 + f0 * 0.3).clamp(-1.0, 1.0);
    }

    return extractMfcc(synth);
  }
}
