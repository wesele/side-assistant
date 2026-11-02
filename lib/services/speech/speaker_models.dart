/// 声纹比对校验结果与详细分析模型
library speaker_models;

import '../../core/ports/speaker_verification_port.dart';

/// 声纹比对校验结果
class SpeakerVerifyResult extends SpeakerVerificationResult {
  const SpeakerVerifyResult({
    required super.isMatched,
    required super.similarity,
    required super.hasEnrolledOwner,
    super.bypassed = false,
    super.reason,
    super.durationMs = 0,
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
class SpeakerAnalysis implements SpeakerAnalysisResult {
  /// 综合得分（0~1），已对多样本做鲁棒聚合
  @override
  final double similarity;

  @override
  final double centroidSimilarity;

  @override
  final double maxSampleSimilarity;

  @override
  final double meanSampleSimilarity;

  @override
  final List<double> sampleSimilarities;

  @override
  final double speechSeconds;

  @override
  final int durationMs;

  @override
  final String? error;

  @override
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

  @override
  bool get hasError => error != null && error!.isNotEmpty;
}
