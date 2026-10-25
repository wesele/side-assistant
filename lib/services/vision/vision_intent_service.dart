import 'dart:math' as math;
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../nlp/embedding_service.dart';
import '../nlp/trigger_matcher.dart';
import '../nlp/vector_math.dart';

class VisionIntentMatchResult {
  final bool isMatched;
  final double similarity;
  final String matchedPrototype;

  const VisionIntentMatchResult({
    required this.isMatched,
    required this.similarity,
    required this.matchedPrototype,
  });

  factory VisionIntentMatchResult.none() {
    return const VisionIntentMatchResult(
      isMatched: false,
      similarity: 0.0,
      matchedPrototype: '',
    );
  }
}

/// 视觉意图识别服务：通过向量语义相似度检测用户提问是否需要捕获摄像头画面发送给大模型
class VisionIntentService {
  final AppSettings settings;
  final EmbeddingService embeddingService;

  final Map<String, List<double>> _prototypeEmbeddings = {};
  bool _isWarmedUp = false;

  VisionIntentService({
    required this.settings,
    required this.embeddingService,
  });

  bool get isWarmedUp => _isWarmedUp;
  Map<String, List<double>> get prototypeEmbeddings => Map.unmodifiable(_prototypeEmbeddings);

  /// 获取当前生效的全量原型词列表（内置原型 + 用户自定义配置）
  List<String> getAllPrototypes() {
    final list = <String>{...AppConstants.defaultVisionPrototypes};
    for (final custom in settings.customVisionPrototypes) {
      final trimmed = custom.trim();
      if (trimmed.isNotEmpty) {
        list.add(trimmed);
      }
    }
    return list.toList();
  }

  /// 预热并缓存视觉意图原型向量池
  Future<void> warmUp({bool force = false}) async {
    if (_isWarmedUp && !force && _prototypeEmbeddings.isNotEmpty) {
      return;
    }

    final prototypes = getAllPrototypes();
    for (final proto in prototypes) {
      if (!_prototypeEmbeddings.containsKey(proto) || force) {
        try {
          final emb = await embeddingService.getEmbedding(proto);
          if (emb.isNotEmpty) {
            _prototypeEmbeddings[proto] = emb;
          }
        } catch (_) {
          // 容错处理：单条原型预热失败不阻断整体流程
        }
      }
    }

    _isWarmedUp = _prototypeEmbeddings.isNotEmpty;
  }

  static final RegExp _photoKeywordRegExp = RegExp(
    r'(拍照|照相|拍一下|拍张照|拍个照|拍张照片|拍下|拍一张|拍摄)',
  );

  /// 视觉意图的极速字面初筛。
  ///
  /// 向量检索需要一次远程 embedding（实测约 300~500ms），如果每句话都先等它，
  /// 语音助手的“回答”结束后会多出明显停顿。这里先用零成本的关键词判断：
  /// 完全不像视觉问题的句子直接跳过 embedding；像的再走原有语义相似度。
  static final RegExp _visionHintRegExp = RegExp(
    r'(看|拍|照|画面|眼前|面前|周围|东西|物体|建筑|花|文字|读一下|识别|长什么样|是什么)',
  );

  /// 检查是否包含显式的“拍照”或直接抓拍动作词
  static bool hasPhotoKeyword(String text) {
    return _photoKeywordRegExp.hasMatch(text);
  }

  /// 是否值得进一步做向量视觉意图识别（极速字面初筛）。
  static bool mightBeVisionIntent(String text) {
    return _visionHintRegExp.hasMatch(text);
  }

  /// 去除标点符号与空白字符
  String _cleanText(String text) => TriggerMatcher.stripAllPunctuation(text);

  /// 校验用户提问是否命中视觉意图
  Future<VisionIntentMatchResult> checkVisionIntent(String userText) async {
    if (!settings.enableVisionIntent) {
      return VisionIntentMatchResult.none();
    }

    final clean = _cleanText(userText);
    if (clean.isEmpty) {
      return VisionIntentMatchResult.none();
    }

    // 1. 规则初筛：若指令明确包含“拍照”或直接抓拍动作词，以 1.0 满分相似度直接命中
    if (hasPhotoKeyword(clean)) {
      return const VisionIntentMatchResult(
        isMatched: true,
        similarity: 1.0,
        matchedPrototype: '拍照指令',
      );
    }

    // 1.5 极速字面初筛：普通问答（天气、时间、播放音乐、打开应用等）
    // 不含任何视觉相关字眼，直接跳过远程 embedding，避免给每句话增加约 0.4s 延迟。
    if (!mightBeVisionIntent(clean)) {
      return VisionIntentMatchResult.none();
    }

    // 确保原型池已预热
    if (_prototypeEmbeddings.isEmpty) {
      await warmUp();
    }

    if (_prototypeEmbeddings.isEmpty) {
      return VisionIntentMatchResult.none();
    }

    try {
      // 视觉问题也要给 embedding 设上限：网络抖动时不能把语音回答无限期卡住。
      final queryEmb = await embeddingService
          .getEmbedding(clean)
          .timeout(const Duration(milliseconds: 800));
      if (queryEmb.isEmpty) {
        return VisionIntentMatchResult.none();
      }

      double bestSim = -1.0;
      String bestProto = '';

      for (final entry in _prototypeEmbeddings.entries) {
        final sim = VectorMath.cosineSimilarity(queryEmb, entry.value);
        if (sim > bestSim) {
          bestSim = sim;
          bestProto = entry.key;
        }
      }

      final isMatched = bestSim >= settings.visionSimilarityThreshold;
      return VisionIntentMatchResult(
        isMatched: isMatched,
        similarity: math.max(0.0, bestSim),
        matchedPrototype: bestProto,
      );
    } catch (_) {
      return VisionIntentMatchResult.none();
    }
  }
}
