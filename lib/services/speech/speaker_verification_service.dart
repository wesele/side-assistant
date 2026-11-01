import 'dart:io';
import 'dart:math' as math;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import '../nlp/vector_math.dart';
import 'asr_service.dart';

/// 声纹比对校验结果
class SpeakerVerifyResult {
  /// 是否判定为主人声纹（若开关未开或未录入声纹，默认放行且 isMatched=true）
  final bool isMatched;

  /// 与主人声纹的最大余弦相似度（-1.0 ~ 1.0）
  final double similarity;

  /// 是否已录制/注册过主人声纹
  final bool hasEnrolledOwner;

  /// 是否跳过了声纹校验（未开启声纹锁开关）
  final bool bypassed;

  /// 状态说明或拦截原因
  final String? reason;

  /// 比对耗时（毫秒）
  final int durationMs;

  const SpeakerVerifyResult({
    required this.isMatched,
    required this.similarity,
    required this.hasEnrolledOwner,
    this.bypassed = false,
    this.reason,
    this.durationMs = 0,
  });

  factory SpeakerVerifyResult.bypassed() => const SpeakerVerifyResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: false,
        bypassed: true,
        reason: '声纹校验未开启',
      );

  factory SpeakerVerifyResult.noOwnerEnrolled() => const SpeakerVerifyResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: false,
        bypassed: true,
        reason: '尚未注册主人声纹，默认放行',
      );

  factory SpeakerVerifyResult.rejected({
    required double similarity,
    required double threshold,
    int durationMs = 0,
  }) =>
      SpeakerVerifyResult(
        isMatched: false,
        similarity: similarity,
        hasEnrolledOwner: true,
        bypassed: false,
        durationMs: durationMs,
        reason:
            '声纹不匹配 (${(similarity * 100).toStringAsFixed(1)}% < ${(threshold * 100).toStringAsFixed(1)}%)',
      );

  /// 声纹锁已开启且已录入主人声纹，但待测音频里没有足够清晰的人声可供比对
  /// （典型场景：电视/远场/蓝牙丢包严重的杂音）。此时无法证明是主人，按拦截处理。
  factory SpeakerVerifyResult.insufficientSpeech({
    required String detail,
    int durationMs = 0,
  }) =>
      SpeakerVerifyResult(
        isMatched: false,
        similarity: 0.0,
        hasEnrolledOwner: true,
        bypassed: false,
        durationMs: durationMs,
        reason: '无足够清晰人声可比对，已拦截 ($detail)',
      );

  factory SpeakerVerifyResult.matched({
    required double similarity,
    int durationMs = 0,
  }) =>
      SpeakerVerifyResult(
        isMatched: true,
        similarity: similarity,
        hasEnrolledOwner: true,
        bypassed: false,
        durationMs: durationMs,
        reason: '声纹匹配成功 (${(similarity * 100).toStringAsFixed(1)}%)',
      );
}

/// 一次声纹比对的详细得分（用于测试面板展示与问题排查）
class SpeakerAnalysis {
  /// 综合得分（0~1），已对多样本做鲁棒聚合
  final double similarity;

  /// 与多样本质心向量的余弦相似度
  final double centroidSimilarity;

  /// 与单个样本的最高余弦相似度
  final double maxSampleSimilarity;

  /// 与所有样本的平均余弦相似度
  final double meanSampleSimilarity;

  /// 与每个已录样本的余弦相似度
  final List<double> sampleSimilarities;

  /// 参与比对的有效语音时长（秒）
  final double speechSeconds;

  /// 比对耗时（毫秒）
  final int durationMs;

  /// 失败原因（无有效语音/特征提取失败等）
  final String? error;

  /// 失败是否因为“没有足够清晰的人声”（而非模型未就绪等系统问题）
  final bool insufficientSpeech;

  const SpeakerAnalysis({
    required this.similarity,
    required this.centroidSimilarity,
    required this.maxSampleSimilarity,
    required this.meanSampleSimilarity,
    required this.sampleSimilarities,
    required this.speechSeconds,
    required this.durationMs,
    this.error,
    this.insufficientSpeech = false,
  });

  factory SpeakerAnalysis.failed(
    String error, {
    int durationMs = 0,
    bool insufficientSpeech = false,
  }) =>
      SpeakerAnalysis(
        insufficientSpeech: insufficientSpeech,
        similarity: 0,
        centroidSimilarity: 0,
        maxSampleSimilarity: 0,
        meanSampleSimilarity: 0,
        sampleSimilarities: const [],
        speechSeconds: 0,
        durationMs: durationMs,
        error: error,
      );

  bool get hasError => error != null && error!.isNotEmpty;
}

/// 主人声纹提取与验证服务
class SpeakerVerificationService {
  final AppSettings settings;

  sherpa_onnx.SpeakerEmbeddingExtractor? _extractor;
  String? _modelPath;
  bool _initializing = false;
  String? _lastEnrollError;

  /// 最近一次声纹样本录入失败的具体原因
  String? get lastEnrollError => _lastEnrollError;


  /// 默认最低有效语音时长（秒）与采样点数
  static const double defaultMinSpeechSeconds = 0.30;
  static const int defaultMinAudioSamples = 4800;

  /// 待校验音频的最低有效语音时长（秒），可由设置项动态调节（0.20s ~ 0.60s）
  double get minSpeechSeconds =>
      settings.speakerMinSpeechSeconds.clamp(0.20, 0.60);

  /// 最低有效语音采样点数（基于当前设置的 minSpeechSeconds 动态计算）
  int get minAudioSamples => (minSpeechSeconds * 16000).round();

  /// 录入声纹模板时的最低有效语音时长（秒），比日常唤醒校验稍严格以确保声纹库质量
  static const double minEnrollSeconds = 0.75;

  /// 最多保存的主人声纹样本向量数量
  static const int maxEnrolledSamples = 5;

  SpeakerVerificationService({required this.settings});

  bool get isReady => _extractor != null;

  int get embeddingDim => _extractor?.dim ?? 0;

  /// 当前加载的声纹模型文件名与特征维度（供设置页/控制台展示）
  String get modelLabel {
    final path = _modelPath;
    if (path == null || path.isEmpty) return '未加载';
    final name = path.replaceAll('\\', '/').split('/').last;
    return '$name (${_extractor?.dim ?? 0} 维)';
  }

  int get enrolledSampleCount {
    if (_extractor == null) return settings.ownerSpeakerEmbeddings.length;
    final dim = _extractor!.dim;
    return settings.ownerSpeakerEmbeddings.where((v) => v.length == dim).length;
  }

  bool get hasEnrolledOwner {
    if (settings.ownerSpeakerEmbeddings.isEmpty) return false;
    if (_extractor == null) return true;
    return settings.ownerSpeakerEmbeddings.any((v) => v.length == _extractor!.dim);
  }

  /// 初始化声纹模型（按需懒加载）
  Future<bool> initialize() async {
    if (_extractor != null) return true;
    if (_initializing) return false;
    _initializing = true;

    try {
      ensureSherpaBindings();

      String? modelPath;
      if (settings.speakerModelPath.trim().isNotEmpty) {
        final customFile = File(settings.speakerModelPath.trim());
        if (customFile.existsSync() && customFile.lengthSync() > 1024) {
          modelPath = customFile.path;
        }
      }

      modelPath ??= await resolveModelPath(
        AppConstants.defaultSpeakerModelAssetPath,
        minBytes: 1024 * 1024,
      );

      // 若首选模型未找到，回退到备用声纹模型
      if (modelPath == null || !File(modelPath).existsSync()) {
        modelPath = await resolveModelPath(
          AppConstants.fallbackSpeakerModelAssetPath,
          minBytes: 1024 * 1024,
        );
      }

      if (modelPath == null || !File(modelPath).existsSync()) {
        debugPrint(
          '[$runtimeType] 未找到声纹模型文件: ${AppConstants.defaultSpeakerModelAssetPath}',
        );
        return false;
      }

      debugPrint('[$runtimeType] 正在加载声纹模型: $modelPath');
      final config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model: modelPath,
        numThreads: 1,
        debug: false,
      );

      _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config: config);
      _modelPath = modelPath;
      debugPrint(
        '[$runtimeType] 声纹模型加载成功，特征维度: ${_extractor!.dim}',
      );

      // 注意：不删除与当前模型维度不一致的旧样本（233 上的用户数据只由用户
      // 主动录入/清空时才变动）。这些旧向量只是不参与比对，
      // enrolledSampleCount / hasEnrolledOwner 会按维度过滤，界面显示 0 个可用样本。
      final stale = settings.ownerSpeakerEmbeddings
          .where((v) => v.length != _extractor!.dim)
          .length;
      if (stale > 0) {
        debugPrint(
          '[$runtimeType] 检测到 $stale 个与当前模型维度(${_extractor!.dim})不一致的'
          '旧声纹样本，已忽略；请重新录制主人声纹',
        );
      }
      return true;
    } catch (e, st) {
      debugPrint('[$runtimeType] 加载声纹模型失败: $e\n$st');
      return false;
    } finally {
      _initializing = false;
    }
  }

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
  static Float32List _highPass80Hz(
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
    final minGap = math.max(12, (sampleRate * 0.001).round()); // ~1ms (16 samples)
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
        if (len >= minGap && len <= maxGap && idx >= 48 && end < samples.length) {
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
                final prev =
                    out[start + ((fillLen + f) % copyPeriod)] * 0.94;
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
  static double _framePitchVoicing(
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
        final normR = r / denom;
        if (normR > maxNormR) {
          maxNormR = normR;
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
          final normR = r / denom;
          if (normR > maxNormR) maxNormR = normR;
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
  }) {
    if (samples.isEmpty) return samples;
    final frame = (sampleRate * 0.025).round();
    final hop = (sampleRate * 0.010).round();
    if (frame <= 0 || hop <= 0 || samples.length < frame) return Float32List(0);

    final repaired =
        concealBluetoothScoDropouts(samples, sampleRate: sampleRate);
    final hpSamples = _highPass80Hz(repaired, sampleRate: sampleRate);
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
    double percentileUngated(double p) =>
        ungated[((ungated.length - 1) * p).round().clamp(0, ungated.length - 1)];

    final sortedAll = Float64List.fromList(energies)..sort();
    double percentileAll(double p) => sortedAll[
        ((sortedAll.length - 1) * p).round().clamp(0, sortedAll.length - 1)];

    final p10 = percentileUngated(0.10);
    final noiseFloor = percentileUngated(0.20);
    final peak = math.max(percentileAll(0.95), percentileUngated(0.90));

    // 1. 绝对能量下限：80Hz 高通后 95%分位帧 RMS 需达到 ~0.0135 (-37.4 dBFS)，排除微弱底噪与远场微弱闷音
    if (peak < 1.85e-4) {
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
    // 要求单帧能量满足绝对下限 4.5e-5 (RMS >= 0.0067) 且达到峰值 8%，
    // 严防蓝牙静音门刚打开时的低电平环境尾音被划入活跃人声段。
    final double baseFloor = !mostlyContinuous
        ? peak * 0.08
        : ((noiseFloor > peak * 0.04)
            ? math.max(p10 * 3.0, peak * 0.08)
            : math.max(noiseFloor * 5.0, peak * 0.08));
    final double effective = math.max(4.5e-5, baseFloor);

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
    final minSegmentFrames = math.max(3, (minSegSec * sampleRate / hop).round());
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
          if (_framePitchVoicing(hpSamples, start, frame, sampleRate) >= 0.45) {
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
  static void _warnIfDropouts(Float32List samples, String stage) {
    final ratio = dropoutRatio(samples);
    if (ratio >= 0.30) {
      debugPrint(
        '[SpeakerVerificationService] ⚠️ $stage音频存在严重丢包：'
        '${(ratio * 100).toStringAsFixed(0)}% 采样点为数字零空洞，'
        '声纹结果不可信（检查蓝牙是否处于 mSBC 模式，建议改用 CVSD 或有线麦克风）',
      );
    }
  }

  /// 提取 16kHz PCM 音频的声纹特征向量
  Float32List? extractEmbedding(
    Float32List samples, {
    int sampleRate = 16000,
    double? minSeconds,
  }) {
    final effectiveMinSec = minSeconds ?? minSpeechSeconds;
    final minRequired = (effectiveMinSec * sampleRate).round();
    if (_extractor == null || samples.length < minRequired) {
      return null;
    }

    try {
      final repaired =
          concealBluetoothScoDropouts(samples, sampleRate: sampleRate);
      final normalized = normalizeWaveform(repaired);
      final stream = _extractor!.createStream();
      stream.acceptWaveform(samples: normalized, sampleRate: sampleRate);
      // 必须显式结束输入，否则特征提取器不会 flush 尾部帧，embedding 会不完整。
      stream.inputFinished();
      if (!_extractor!.isReady(stream)) {
        stream.free();
        debugPrint('[$runtimeType] 声纹特征未就绪（音频过短或无效）');
        return null;
      }
      final embedding = _extractor!.compute(stream);
      stream.free();

      if (embedding.isEmpty || embedding.length != _extractor!.dim) {
        return null;
      }
      return embedding;
    } catch (e, st) {
      debugPrint('[$runtimeType] 提取声纹特征异常: $e\n$st');
      return null;
    }
  }

  /// 录入/追加一段主人声纹样本
  Future<bool> enrollOwner(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    _lastEnrollError = null;
    if (!isReady) {
      final ok = await initialize();
      if (!ok) {
        _lastEnrollError = '声纹模型未就绪';
        return false;
      }
    }

    final minEnrollSamples = (minEnrollSeconds * sampleRate).round();
    _warnIfDropouts(samples, '录入');
    final trimmed = trimToSpeech(
      samples,
      sampleRate: sampleRate,
      minSeconds: minEnrollSeconds,
    );
    if (trimmed.length < minEnrollSamples) {
      _lastEnrollError =
          '未检测到足够时长的清晰人声（请靠近麦克风连续清晰朗读 2~3 秒，避免停顿过长或只录到环境闷音）';
      debugPrint('[$runtimeType] 录制声纹失败：$_lastEnrollError');
      return false;
    }

    final emb = extractEmbedding(trimmed, sampleRate: sampleRate);
    if (emb == null || emb.isEmpty) {
      _lastEnrollError = '有效音频过短或声纹特征提取失败';
      debugPrint('[$runtimeType] 录制声纹失败：$_lastEnrollError');
      return false;
    }

    final vector = emb.map((e) => e.toDouble()).toList();
    final current = List<List<double>>.from(settings.ownerSpeakerEmbeddings);

    // 清理不同维度的历史样本（例如从旧模型切换后遗留的样本）
    current.removeWhere((v) => v.length != vector.length);

    // 录入质量诊断：若新录制的有效人声与旧声纹库质心差异极大 (< 22%)，
    // 说明旧声纹库可能由不同麦克风或旧版未修复蓝牙丢包的底噪录成，自动归档重置旧样本以当前纯净样本为新基准。
    if (current.isNotEmpty) {
      final centroid = List<double>.filled(vector.length, 0.0);
      for (final v in current) {
        for (int i = 0; i < vector.length; i++) {
          centroid[i] += v[i] / current.length;
        }
      }
      final consistency = VectorMath.cosineSimilarity(vector, centroid);
      debugPrint(
        '[$runtimeType] 新样本与已有声纹质心相似度: '
        '${(consistency * 100).toStringAsFixed(1)}% (有效人声 ${(trimmed.length / sampleRate).toStringAsFixed(2)}s)',
      );
      if (consistency < 0.22) {
        debugPrint(
          '[$runtimeType] 检测到新样本与历史声纹库声学域差异过大 '
          '(${(consistency * 100).toStringAsFixed(1)}% < 22%)，自动清空旧污染样本并以本次新样本作为基准',
        );
        current.clear();
      } else if (consistency < 0.40) {
        debugPrint(
          '[$runtimeType] 警告：新样本与已录声纹存在一定差异 (${(consistency * 100).toStringAsFixed(1)}%)',
        );
      }
    }

    current.add(vector);

    // 最多保留最近的 maxEnrolledSamples 个样本
    if (current.length > maxEnrolledSamples) {
      current.removeRange(0, current.length - maxEnrolledSamples);
    }

    settings.ownerSpeakerEmbeddings = current;
    await settings.save();
    debugPrint(
      '[$runtimeType] 主人声纹录入成功，当前共有 ${current.length} 个样本 '
      '(特征维度: ${vector.length}, 有效人声: ${(trimmed.length / sampleRate).toStringAsFixed(2)}s)',
    );
    return true;
  }

  /// 清空已录入的主人声纹
  Future<void> clearOwnerEmbeddings() async {
    settings.ownerSpeakerEmbeddings = [];
    await settings.save();
    debugPrint('[$runtimeType] 已清空主人声纹样本');
  }

  /// 计算待测向量与主人声纹库的鲁棒综合余弦相似度（质心 + 全样本均值聚合）
  double computeMaxSimilarity(List<double> candidate) {
    return computeMatchScore(candidate)?.similarity ?? 0.0;
  }

  /// 计算鲁棒综合得分，并返回每个样本的明细。
  ///
  /// 与 [computeMaxSimilarity] 的区别：不再取“单个样本最高分”，避免某一个被污染
  /// 的样本（例如误录进电视声）把整体分数抬高；改为质心相似度 + 全样本均值。
  SpeakerAnalysis? computeMatchScore(
    List<double> candidate, {
    double speechSeconds = 0,
    int durationMs = 0,
  }) {
    if (candidate.isEmpty) return null;
    final dim = candidate.length;
    final enrolled = settings.ownerSpeakerEmbeddings
        .where((v) => v.length == dim)
        .toList(growable: false);
    if (enrolled.isEmpty) return null;

    final sampleSims = enrolled
        .map((v) => VectorMath.cosineSimilarity(candidate, v).clamp(-1.0, 1.0))
        .toList(growable: false);
    final maxSim = sampleSims.reduce(math.max);
    final meanSim =
        sampleSims.reduce((a, b) => a + b) / sampleSims.length.toDouble();

    final centroid = List<double>.filled(dim, 0.0);
    for (final v in enrolled) {
      for (int i = 0; i < dim; i++) {
        centroid[i] += v[i] / enrolled.length;
      }
    }
    final centroidSim =
        VectorMath.cosineSimilarity(candidate, centroid).clamp(-1.0, 1.0);

    // 综合得分：
    // - 单样本：直接用该样本相似度；
    // - 多样本：质心相似度天然高于“逐样本平均”（质心把各样本噪声抵消了，
    //   对任何人都偏乐观），因此以逐样本均值为主、质心为辅（0.7 / 0.3）；
    //   样本数 >= 4 时先剔除最低的一个样本再取均值，抑制被污染的离群样本。
    double robustMean = meanSim;
    if (enrolled.length >= 4) {
      final sorted = List<double>.from(sampleSims)..sort();
      final kept = sorted.sublist(1);
      robustMean = kept.reduce((a, b) => a + b) / kept.length;
    }
    final score = enrolled.length == 1
        ? sampleSims.first
        : (0.3 * centroidSim + 0.7 * robustMean).clamp(-1.0, 1.0);

    return SpeakerAnalysis(
      similarity: score,
      centroidSimilarity: centroidSim,
      maxSampleSimilarity: maxSim,
      meanSampleSimilarity: meanSim,
      sampleSimilarities: sampleSims,
      speechSeconds: speechSeconds,
      durationMs: durationMs,
    );
  }

  /// 对一段音频做完整的声纹比对分析（不考虑声纹锁开关，供测试面板使用）。
  SpeakerAnalysis analyzeOwner(
    Float32List samples, {
    int sampleRate = 16000,
    double? customMinSpeechSeconds,
  }) {
    final sw = Stopwatch()..start();
    if (!isReady) {
      return SpeakerAnalysis.failed('声纹模型未初始化');
    }
    if (enrolledSampleCount == 0) {
      return SpeakerAnalysis.failed('尚未录入主人声纹');
    }

    final effectiveMinSec =
        (customMinSpeechSeconds ?? minSpeechSeconds).clamp(0.20, 0.60);
    final minRequired = (effectiveMinSec * sampleRate).round();

    _warnIfDropouts(samples, '比对');
    final trimmed = trimToSpeech(
      samples,
      sampleRate: sampleRate,
      minSeconds: effectiveMinSec,
    );
    if (trimmed.length < minRequired) {
      sw.stop();
      return SpeakerAnalysis.failed(
        '未检测到足够时长的有效人声（需 ≥${effectiveMinSec.toStringAsFixed(2)} 秒）',
        durationMs: sw.elapsedMilliseconds,
        insufficientSpeech: true,
      );
    }

    final emb = extractEmbedding(
      trimmed,
      sampleRate: sampleRate,
      minSeconds: effectiveMinSec,
    );
    if (emb == null || emb.isEmpty) {
      sw.stop();
      return SpeakerAnalysis.failed(
        '声纹特征提取失败',
        durationMs: sw.elapsedMilliseconds,
        insufficientSpeech: true,
      );
    }

    final candidate = emb.map((e) => e.toDouble()).toList(growable: false);
    final analysis = computeMatchScore(
      candidate,
      speechSeconds: trimmed.length / sampleRate,
      durationMs: sw.elapsedMilliseconds,
    );
    sw.stop();
    if (analysis == null) {
      return SpeakerAnalysis.failed(
        '没有与当前模型维度一致的声纹样本，请重新录制',
        durationMs: sw.elapsedMilliseconds,
      );
    }
    return analysis;
  }

  /// 校验待测音频是否匹配主人声纹
  SpeakerVerifyResult verifyOwner(
    Float32List samples, {
    int sampleRate = 16000,
    double? customThreshold,
    double? customMinSpeechSeconds,
  }) {
    // 1. 若未开启开关，直接放行
    if (!settings.enableSpeakerVerification) {
      return SpeakerVerifyResult.bypassed();
    }

    // 2. 若尚未录入声纹样本，默认放行
    if (settings.ownerSpeakerEmbeddings.isEmpty) {
      return SpeakerVerifyResult.noOwnerEnrolled();
    }

    // 3. 模型未就绪
    if (!isReady) {
      return const SpeakerVerifyResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: true,
        bypassed: true,
        reason: '声纹模型未初始化，放行',
      );
    }

    // 3.5 检查已录入样本特征维度是否与当前加载模型一致（例如从 192 维切换为 512 维时）
    final dim = _extractor!.dim;
    final hasMatchingDim =
        settings.ownerSpeakerEmbeddings.any((v) => v.length == dim);
    if (!hasMatchingDim) {
      return const SpeakerVerifyResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: false,
        bypassed: true,
        reason: '已录制声纹特征维度与当前模型不一致，已自动放行，请在控制台重新录制声纹',
      );
    }

    final effectiveMinSec =
        (customMinSpeechSeconds ?? minSpeechSeconds).clamp(0.20, 0.60);
    final minRequired = (effectiveMinSec * sampleRate).round();

    // 4. 音频有效时长检查
    if (samples.length < minRequired) {
      debugPrint(
        '[$runtimeType] 音频过短 (${samples.length} < $minRequired)，无法证明是主人，拦截',
      );
      return SpeakerVerifyResult.insufficientSpeech(
        detail: '音频 <${effectiveMinSec.toStringAsFixed(2)}s',
      );
    }

    final analysis = analyzeOwner(
      samples,
      sampleRate: sampleRate,
      customMinSpeechSeconds: effectiveMinSec,
    );
    if (analysis.hasError && analysis.insufficientSpeech) {
      // 已开启声纹锁且已录入主人声纹：没有足够清晰的人声就无法证明是主人，
      // 不能因为“识别不了”而放行（否则电视/杂音恰好借此绕过声纹锁）。
      debugPrint('[$runtimeType] ${analysis.error}，按未通过处理');
      return SpeakerVerifyResult.insufficientSpeech(
        detail: analysis.error!,
        durationMs: analysis.durationMs,
      );
    }
    if (analysis.hasError) {
      debugPrint('[$runtimeType] ${analysis.error}，跳过声纹拦截');
      return SpeakerVerifyResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: true,
        bypassed: true,
        durationMs: analysis.durationMs,
        reason: '${analysis.error}，放行',
      );
    }

    final similarity = analysis.similarity;
    final threshold = customThreshold ?? settings.speakerSimilarityThreshold;
    if (similarity >= threshold) {
      return SpeakerVerifyResult.matched(
        similarity: similarity,
        durationMs: analysis.durationMs,
      );
    } else {
      return SpeakerVerifyResult.rejected(
        similarity: similarity,
        threshold: threshold,
        durationMs: analysis.durationMs,
      );
    }
  }

  /// 保存最近一次声纹测试音频，便于排查“电视声也高分”等问题。
  /// 文件固定覆盖，仅保留最后一次，位于应用 support 目录。
  static Future<String?> saveDebugWave(
    Float32List samples, {
    String fileName = 'speaker_test_last.wav',
  }) async {
    try {
      if (samples.isEmpty) return null;
      final dir = await StorageBridge.getAppSupportDirectory();
      final path = '${dir.path}${Platform.pathSeparator}$fileName';
      if (sherpa_onnx.writeWave(
        filename: path,
        samples: samples,
        sampleRate: 16000,
      )) {
        debugPrint('[SpeakerVerificationService] 已保存声纹测试音频: $path');
        return path;
      }
    } catch (e) {
      debugPrint('[SpeakerVerificationService] 保存声纹测试音频失败: $e');
    }
    return null;
  }

  void dispose() {
    _extractor?.free();
    _extractor = null;
  }
}
