import 'dart:typed_data';

import '../models/app_settings.dart';

/// 声纹校验仲裁结果 (Speaker Verification Result)
///
/// 封装声纹比对的匹配状态、置信度分数、判定原因与耗时。
class SpeakerVerificationResult {
  /// 是否匹配已注册主人声纹
  final bool isMatched;

  /// 余弦相似度分数 (0.0 ~ 1.0)
  final double similarity;

  /// 系统中是否存在已注册的主人声纹
  final bool hasEnrolledOwner;

  /// 是否放行/跳过校验（例如声纹功能未开启或未录入主人）
  final bool bypassed;

  /// 决策原因或拦截描述说明
  final String? reason;

  /// 声纹特征提取与比对耗时（毫秒）
  final int durationMs;

  const SpeakerVerificationResult({
    required this.isMatched,
    required this.similarity,
    required this.hasEnrolledOwner,
    this.bypassed = false,
    this.reason,
    this.durationMs = 0,
  });

  factory SpeakerVerificationResult.bypassed({String reason = '声纹校验未开启或跳过'}) =>
      SpeakerVerificationResult(
        isMatched: true,
        similarity: 1.0,
        hasEnrolledOwner: false,
        bypassed: true,
        reason: reason,
      );

  factory SpeakerVerificationResult.matched({
    double similarity = 1.0,
    int durationMs = 0,
    String? reason,
  }) =>
      SpeakerVerificationResult(
        isMatched: true,
        similarity: similarity,
        hasEnrolledOwner: true,
        bypassed: false,
        durationMs: durationMs,
        reason: reason ?? '主人声纹比对通过',
      );

  factory SpeakerVerificationResult.rejected({
    required double similarity,
    required double threshold,
    int durationMs = 0,
    String? reason,
  }) =>
      SpeakerVerificationResult(
        isMatched: false,
        similarity: similarity,
        hasEnrolledOwner: true,
        bypassed: false,
        durationMs: durationMs,
        reason: reason ??
            '声纹不匹配 (${(similarity * 100).toStringAsFixed(1)}% < ${(threshold * 100).toStringAsFixed(1)}%)',
      );
}

/// 声纹校验与录入门禁契约端口 (Speaker Verification Port)
///
/// 遵循接口隔离原则 (ISP)，将主人声纹相似度仲裁与样本录制门禁检查
/// 从具体语音管线抽象为轻量级契约。
/// 对话编排协调器及外部调用者仅依赖此端口，与具体声学采集与算法模型解耦。
/// 纯 Dart 契约，零 `dart:ui` 或 `package:flutter` 依赖。
abstract interface class SpeakerVerificationPort {
  /// 当前是否正在录制声纹样本（录制中需丢弃常规 ASR 识别流与待机唤醒）
  bool get isEnrolling;

  /// 校验当前输入音频是否来自已注册的主人声纹
  ///
  /// 基于语音管线内部最近捕获的音频流缓冲（2.5 秒环形缓存），结合上下文自适应门限进行余弦相似度校验。
  /// [contextHint] 用于日志描述与短语境门限自适应（如“待机语音”、“提问内容”、“打断播报”等）。
  /// [onRejected] 校验未通过时的业务回调（附带原因描述，如状态提示）。
  /// 返回 true 表示校验通过或被旁路放行，false 表示拦截。
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  });

  /// 校验指定原始 PCM 字节数据是否匹配主人声纹
  ///
  /// 供外部音频源、测试固件或显式 PCM 抓采数据使用，将 PCM 数据转换为声学特征并比对。
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  });
}

/// 声纹分析详细结果契约
abstract interface class SpeakerAnalysisResult {
  bool get hasError;
  String? get error;
  double get similarity;
  double get centroidSimilarity;
  double get maxSampleSimilarity;
  double get meanSampleSimilarity;
  List<double> get sampleSimilarities;
  double get speechSeconds;
  int get durationMs;
  bool get insufficientSpeech;
}

/// 声纹特征提取与比对底层引擎契约 (Speaker Verifier Engine Port)
abstract interface class SpeakerVerifierPort {
  int get enrolledSampleCount;
  bool get hasEnrolledOwner;
  String get modelLabel;
  String? get lastEnrollError;
  bool get isReady;
  double get energyThreshold;
  int get minAudioSamples;
  double get minSpeechSeconds;
  Future<bool> initialize();
  SpeakerVerificationResult verifyOwner(
    Float32List audio, {
    int sampleRate = 16000,
    double? customThreshold,
    double? customMinSpeechSeconds,
    String contextHint = '唤醒',
  });
  Future<bool> enrollOwner(Float32List audio);
  Future<void> clearOwnerEmbeddings();
  SpeakerAnalysisResult analyzeOwner(Float32List audio);
  Future<String?> saveDebugWave(
    Float32List samples, {
    String fileName = 'speaker_test_last.wav',
  });
  Float32List trimAudioToSpeech(
    Float32List samples, {
    double minSeconds = 0.75,
  });
  void dispose();
}

/// 声纹服务 SPI 工厂注册表
class SpeakerVerifierFactoryRegistry {
  static SpeakerVerifierPort Function(AppSettings settings)? defaultFactory;
}
