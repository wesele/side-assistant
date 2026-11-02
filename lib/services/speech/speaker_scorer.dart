import 'dart:math' as math;

import '../nlp/vector_math.dart';
import 'speaker_models.dart';

/// 声纹相似度打分与多样本质心聚合算法
class SpeakerScorer {
  /// 计算多个声纹向量的均值质心向量
  static List<double> computeCentroid(List<List<double>> embeddings, int dim) {
    if (embeddings.isEmpty || dim <= 0) return const [];
    final centroid = List<double>.filled(dim, 0.0);
    for (final v in embeddings) {
      for (int i = 0; i < dim; i++) {
        centroid[i] += v[i] / embeddings.length;
      }
    }
    return centroid;
  }

  /// 计算待测向量与主人声纹库的鲁棒综合得分与详细明细。
  ///
  /// 综合得分：
  /// - 单样本：直接使用该样本相似度；
  /// - 多样本：质心相似度天然高于“逐样本平均”（质心把各样本噪声抵消了，
  ///   对任何人都偏乐观），因此以逐样本均值为主、质心为辅（0.7 / 0.3）；
  ///   样本数 >= 4 时先剔除最低的一个样本再取均值，抑制被污染的离群样本。
  static SpeakerAnalysis? computeMatchScore({
    required List<double> candidate,
    required List<List<double>> enrolledEmbeddings,
    double speechSeconds = 0,
    int durationMs = 0,
  }) {
    if (candidate.isEmpty) return null;
    final dim = candidate.length;
    final enrolled = enrolledEmbeddings
        .where((v) => v.length == dim)
        .toList(growable: false);
    if (enrolled.isEmpty) return null;

    final sampleSims = enrolled
        .map((v) => VectorMath.cosineSimilarity(candidate, v).clamp(-1.0, 1.0))
        .toList(growable: false);
    final maxSim = sampleSims.reduce(math.max);
    final meanSim =
        sampleSims.reduce((a, b) => a + b) / sampleSims.length.toDouble();

    final centroid = computeCentroid(enrolled, dim);
    final centroidSim =
        VectorMath.cosineSimilarity(candidate, centroid).clamp(-1.0, 1.0);

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

  /// 计算待测向量与声纹库的综合相似度浮点分值
  static double computeMaxSimilarity({
    required List<double> candidate,
    required List<List<double>> enrolledEmbeddings,
  }) {
    return computeMatchScore(
          candidate: candidate,
          enrolledEmbeddings: enrolledEmbeddings,
        )?.similarity ??
        0.0;
  }
}
