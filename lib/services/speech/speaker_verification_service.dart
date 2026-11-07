import 'dart:io';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/audio_input_device_kind.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import '../../core/ports/speaker_verification_port.dart';
import '../nlp/vector_math.dart';
import 'asr_service.dart';
import 'speaker_audio_processor.dart';
import 'speaker_domain_registry.dart';
import 'speaker_models.dart';
import 'speaker_scorer.dart';

export 'speaker_audio_processor.dart';
export 'speaker_domain_registry.dart';
export 'speaker_models.dart';
export 'speaker_scorer.dart';

/// 主人声纹提取与验证服务
class SpeakerVerificationService implements SpeakerVerifierPort {
  final AppSettings settings;

  sherpa_onnx.SpeakerEmbeddingExtractor? _extractor;
  String? _modelPath;
  bool _initializing = false;
  String? _lastEnrollError;

  /// 最近一次声纹样本录入失败的具体原因
  @override
  String? get lastEnrollError => _lastEnrollError;

  /// 默认最低有效语音时长（秒）与采样点数
  static const double defaultMinSpeechSeconds =
      SpeakerAudioProcessor.defaultMinSpeechSeconds;
  static const int defaultMinAudioSamples =
      SpeakerAudioProcessor.defaultMinAudioSamples;

  /// 待校验音频的最低有效语音时长（秒），可由设置项动态调节（0.20s ~ 0.60s）
  @override
  double get minSpeechSeconds =>
      settings.speakerMinSpeechSeconds.clamp(0.20, 0.60);

  /// 待校验音频的有效人声能量起振门限，可由设置项动态调节（1e-5 ~ 2.5e-4）
  @override
  double get energyThreshold =>
      settings.speakerEnergyThreshold.clamp(1e-5, 2.5e-4);

  /// 最低有效语音采样点数（基于当前设置的 minSpeechSeconds 动态计算）
  @override
  int get minAudioSamples => (minSpeechSeconds * 16000).round();

  /// 录入声纹模板时的最低有效语音时长（秒），比日常唤醒校验稍严格以确保声纹库质量
  static const double minEnrollSeconds = 0.75;

  /// 每个声学域最多保存的样本数（宽带 / 窄带各自独立计数）
  static const int maxEnrolledSamples = 5;

  /// 所有声学域合计最多保存的样本数，避免长期切换音源后无限膨胀
  static const int maxTotalEnrolledSamples = 10;

  /// 同域内新样本与旧质心的余弦相似度低于此值时，判定模板已被污染，
  /// 只清空「当前域」的样本重建基准，其它音源的模板保持不动。
  static const double domainMismatchResetThreshold = 0.35;

  /// 是否已经提示过「当前音源尚无专属模板」，避免高频比对刷屏日志。
  bool _domainFallbackWarned = false;

  /// 当前音源所属的声学域（配置优先，信号丢包指纹兜底）。
  String currentAcousticDomain({bool narrowbandSignal = false}) =>
      speakerDomainFor(
        deviceLabel: settings.audioInputDeviceLabel,
        deviceId: settings.audioInputDeviceId,
        narrowbandSignal: narrowbandSignal,
      );

  /// 按声学域挑选参与比对的模板。
  ({List<List<double>> templates, bool usedFallback}) _templatesForDomain(
    String domain,
  ) {
    final book = SpeakerDomainBook.fromStored(
      settings.ownerSpeakerEmbeddings,
      settings.ownerSpeakerDomains,
    );
    final selection = book.templatesFor(domain);
    if (selection.usedFallback && !_domainFallbackWarned) {
      _domainFallbackWarned = true;
      debugPrint(
        '[$runtimeType] ⚠️ 当前音源($domain)尚无专属声纹模板，暂时混用历史模板；'
        '请用当前麦克风补录 3~5 条声纹以恢复准确率',
      );
    } else if (!selection.usedFallback) {
      _domainFallbackWarned = false;
    }
    return selection;
  }

  SpeakerVerificationService({required this.settings});

  @override
  bool get isReady => _extractor != null;

  int get embeddingDim => _extractor?.dim ?? 0;

  /// 当前加载的声纹模型文件名与特征维度（供设置页/控制台展示）
  @override
  String get modelLabel {
    final path = _modelPath;
    if (path == null || path.isEmpty) return '未加载';
    final name = path.replaceAll('\\', '/').split('/').last;
    return '$name (${_extractor?.dim ?? 0} 维)';
  }

  @override
  int get enrolledSampleCount {
    if (_extractor == null) return settings.ownerSpeakerEmbeddings.length;
    final dim = _extractor!.dim;
    return settings.ownerSpeakerEmbeddings.where((v) => v.length == dim).length;
  }

  @override
  bool get hasEnrolledOwner {
    if (settings.ownerSpeakerEmbeddings.isEmpty) return false;
    if (_extractor == null) return true;
    return settings.ownerSpeakerEmbeddings
        .any((v) => v.length == _extractor!.dim);
  }

  /// 初始化声纹模型（按需懒加载）
  @override
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
  static Float32List normalizeWaveform(Float32List samples) =>
      SpeakerAudioProcessor.normalizeWaveform(samples);

  /// 修复蓝牙 HFP/SCO (mSBC/CVSD) 链路丢包或 PipeWire 周期性欠载导致的短时数字零空洞（Packet Loss Concealment, PLC）。
  static Float32List concealBluetoothScoDropouts(
    Float32List samples, {
    int sampleRate = 16000,
  }) =>
      SpeakerAudioProcessor.concealBluetoothScoDropouts(
        samples,
        sampleRate: sampleRate,
      );

  /// 基于短时能量、声带基音谐波周期性 (Voicing) 与高频共振峰特性的活跃人声抽取
  static Float32List trimToSpeech(
    Float32List samples, {
    int sampleRate = 16000,
    double minSeconds = defaultMinSpeechSeconds,
    double? customEnergyThreshold,
    bool forceNarrowband = false,
  }) =>
      SpeakerAudioProcessor.trimToSpeech(
        samples,
        sampleRate: sampleRate,
        minSeconds: minSeconds,
        customEnergyThreshold: customEnergyThreshold,
        forceNarrowband: forceNarrowband,
      );

  /// 统计音频中被“短时数字零空洞”（1ms~36ms 连续纯零）占据的采样点比例
  static double dropoutRatio(Float32List samples, {int sampleRate = 16000}) =>
      SpeakerAudioProcessor.dropoutRatio(samples, sampleRate: sampleRate);

  @override
  Float32List trimAudioToSpeech(
    Float32List samples, {
    double minSeconds = 0.75,
  }) =>
      trimToSpeech(
        samples,
        minSeconds: minSeconds,
        customEnergyThreshold: energyThreshold,
        forceNarrowband: currentAcousticDomain() == speakerDomainNarrowband,
      );

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
      final repaired = SpeakerAudioProcessor.concealBluetoothScoDropouts(
          samples,
          sampleRate: sampleRate);
      final normalized = SpeakerAudioProcessor.normalizeWaveform(repaired);
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
  @override
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
    SpeakerAudioProcessor.warnIfDropouts(samples, '录入');
    final trimOutcome = SpeakerAudioProcessor.trimToSpeechDetailed(
      samples,
      sampleRate: sampleRate,
      minSeconds: minEnrollSeconds,
      customEnergyThreshold: energyThreshold,
      forceNarrowband: currentAcousticDomain() == speakerDomainNarrowband,
    );
    final trimmed = trimOutcome.samples;
    if (trimmed.length < minEnrollSamples) {
      final diag = trimOutcome.diagnostic;
      _lastEnrollError = diag.isPass
          ? '有效语音仅 ${(trimmed.length / sampleRate).toStringAsFixed(2)}s'
              '（需 ≥${minEnrollSeconds.toStringAsFixed(2)}s，请连续清晰朗读 2~3 秒）'
          : '人声质量门禁拒绝 [${diag.stage}]：${diag.summary}'
              '（请靠近麦克风连续清晰朗读 2~3 秒）';
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
    final domain = currentAcousticDomain(
      narrowbandSignal: trimOutcome.diagnostic.bluetoothNarrowband,
    );
    final book = SpeakerDomainBook.fromStored(
      settings.ownerSpeakerEmbeddings,
      settings.ownerSpeakerDomains,
    );

    // 清理不同维度的历史样本（例如从旧模型切换后遗留的样本）
    for (var i = book.length - 1; i >= 0; i--) {
      if (book.embeddings[i].length != vector.length) book.removeAt(i);
    }

    // 录入质量诊断：只与「当前音源域」的质心比较。
    // 跨域差异（宽带模板 vs 8kHz 蓝牙 HFP 窄带）是预期现象，不再清空整库——
    // 旧域模板保留下来，音源切回去时可以直接复用，无需再次录制。
    final sameDomain = <List<double>>[];
    for (var i = 0; i < book.length; i++) {
      if (book.domains[i] == domain) sameDomain.add(book.embeddings[i]);
    }
    if (sameDomain.isNotEmpty) {
      final centroid = SpeakerScorer.computeCentroid(sameDomain, vector.length);
      final consistency = VectorMath.cosineSimilarity(vector, centroid);
      debugPrint(
        '[$runtimeType] 新样本与 $domain 域质心相似度: '
        '${(consistency * 100).toStringAsFixed(1)}% (有效人声 ${(trimmed.length / sampleRate).toStringAsFixed(2)}s)',
      );
      if (consistency < domainMismatchResetThreshold) {
        final removed = book.clearDomain(domain);
        debugPrint(
          '[$runtimeType] $domain 域模板已污染 '
          '(${(consistency * 100).toStringAsFixed(1)}% < ${(domainMismatchResetThreshold * 100).toStringAsFixed(0)}%)，'
          '清空该域 $removed 条样本重建基准（其它音源域 ${book.length} 条保持不变）',
        );
      } else if (consistency < 0.50) {
        debugPrint(
          '[$runtimeType] 警告：新样本与 $domain 域已录声纹存在一定差异 (${(consistency * 100).toStringAsFixed(1)}%)',
        );
      }
    } else {
      debugPrint(
        '[$runtimeType] 当前音源($domain)首次录入，保留其它音源域的 ${book.length} 条历史模板',
      );
    }

    book.add(vector, domain);
    book.trim(
      maxPerDomain: maxEnrolledSamples,
      maxTotal: maxTotalEnrolledSamples,
    );

    settings.ownerSpeakerEmbeddings = book.embeddings;
    settings.ownerSpeakerDomains = book.domains;
    await settings.save();
    _domainFallbackWarned = false;
    final domainCount = book.domains.where((d) => d == domain).length;
    debugPrint(
      '[$runtimeType] 主人声纹录入成功，当前共有 ${book.length} 个样本 '
      '($domain 域 $domainCount 条, 特征维度: ${vector.length}, '
      '有效人声: ${(trimmed.length / sampleRate).toStringAsFixed(2)}s)',
    );
    return true;
  }

  /// 清空已录入的主人声纹
  @override
  Future<void> clearOwnerEmbeddings() async {
    settings.ownerSpeakerEmbeddings = [];
    settings.ownerSpeakerDomains = [];
    _domainFallbackWarned = false;
    await settings.save();
    debugPrint('[$runtimeType] 已清空全部音源域的主人声纹样本');
  }

  /// 计算待测向量与「当前音源域」主人声纹库的鲁棒综合余弦相似度。
  double computeMaxSimilarity(List<double> candidate, {String? domain}) {
    final effectiveDomain = domain ?? currentAcousticDomain();
    return SpeakerScorer.computeMaxSimilarity(
      candidate: candidate,
      enrolledEmbeddings: _templatesForDomain(effectiveDomain).templates,
    );
  }

  /// 计算鲁棒综合得分，并返回每个样本的明细。
  SpeakerAnalysis? computeMatchScore(
    List<double> candidate, {
    double speechSeconds = 0,
    int durationMs = 0,
    String? domain,
  }) {
    return SpeakerScorer.computeMatchScore(
      candidate: candidate,
      enrolledEmbeddings:
          _templatesForDomain(domain ?? currentAcousticDomain()).templates,
      speechSeconds: speechSeconds,
      durationMs: durationMs,
    );
  }

  /// 对一段音频做完整的声纹比对分析（不考虑声纹锁开关，供测试面板使用）。
  @override
  SpeakerAnalysis analyzeOwner(
    Float32List samples, {
    int sampleRate = 16000,
    double? customMinSpeechSeconds,
    double? customEnergyThreshold,
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
    final effectiveEnergy =
        (customEnergyThreshold ?? energyThreshold).clamp(1.0e-5, 2.5e-4);

    SpeakerAudioProcessor.warnIfDropouts(samples, '比对');
    final trimOutcome = SpeakerAudioProcessor.trimToSpeechDetailed(
      samples,
      sampleRate: sampleRate,
      minSeconds: effectiveMinSec,
      customEnergyThreshold: effectiveEnergy,
      forceNarrowband: currentAcousticDomain() == speakerDomainNarrowband,
    );
    final diag = trimOutcome.diagnostic;
    if (!diag.isPass || trimOutcome.samples.length < minRequired) {
      sw.stop();
      // 区分「PCM 确实太短」与「质量门禁把音频裁成空」，避免所有失败都被
      // 笼统报成「时长不够」而掩盖蓝牙窄带链路的真实问题。
      final String detail;
      if (samples.length < minRequired) {
        detail = '输入音频仅 '
            '${(samples.length / sampleRate).toStringAsFixed(2)}s'
            '（需 ≥${effectiveMinSec.toStringAsFixed(2)}s）';
      } else if (diag.isPass) {
        detail = '裁剪后有效语音仅 '
            '${(trimOutcome.samples.length / sampleRate).toStringAsFixed(2)}s'
            '（需 ≥${effectiveMinSec.toStringAsFixed(2)}s）';
      } else {
        detail = '人声质量门禁拒绝 [${diag.stage}]：${diag.summary}';
      }
      return SpeakerAnalysis.failed(
        '声纹前置检查未通过：$detail',
        durationMs: sw.elapsedMilliseconds,
        insufficientSpeech: true,
      );
    }
    final trimmed = trimOutcome.samples;

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
      domain: currentAcousticDomain(
        narrowbandSignal: diag.bluetoothNarrowband,
      ),
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
  @override
  SpeakerVerifyResult verifyOwner(
    Float32List samples, {
    int sampleRate = 16000,
    double? customThreshold,
    double? customMinSpeechSeconds,
    String contextHint = '唤醒',
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
      customEnergyThreshold: energyThreshold,
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

  @override
  Future<String?> saveDebugWave(
    Float32List samples, {
    String fileName = 'speaker_test_last.wav',
  }) =>
      saveDebugWaveStatic(samples, fileName: fileName);

  /// 保存最近一次声纹测试音频，便于排查“电视声也高分”等问题。
  /// 文件固定覆盖，仅保留最后一次，位于应用 support 目录。
  static Future<String?> saveDebugWaveStatic(
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

  @override
  void dispose() {
    _extractor?.free();
    _extractor = null;
  }
}
