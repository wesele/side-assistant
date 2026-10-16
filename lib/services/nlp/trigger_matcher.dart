import 'dart:math' as math;
import 'package:lpinyin/lpinyin.dart';
import '../../core/models/app_settings.dart';
import 'embedding_service.dart';
import 'vector_math.dart';

enum TriggerType {
  none,
  start,
  end,
  reset,
}

class TriggerMatchResult {
  final TriggerType type;
  final String matchedText;
  final int startIndex;
  final int endIndex;
  final double similarity;
  final String method; // 'exact', 'pinyin', 'semantic_vector'

  TriggerMatchResult({
    required this.type,
    required this.matchedText,
    required this.similarity,
    required this.method,
    this.startIndex = -1,
    this.endIndex = -1,
  });

  factory TriggerMatchResult.none() {
    return TriggerMatchResult(
      type: TriggerType.none,
      matchedText: '',
      similarity: 0.0,
      method: 'none',
      startIndex: -1,
      endIndex: -1,
    );
  }

  bool get isMatched => type != TriggerType.none;
}

/// 一句话完整提问（单次一并包含开始词、提问内容、结束词）
class ExtractedCommand {
  final String startWord;
  final String promptContent;
  final String endWord;

  const ExtractedCommand({
    required this.startWord,
    required this.promptContent,
    required this.endWord,
  });
}

class TriggerMatcher {
  final AppSettings settings;
  final EmbeddingService embeddingService;

  List<double>? _startWordEmbedding;
  List<double>? _endWordEmbedding;
  List<double>? _resetWordEmbedding;

  /// 开始词多原型向量池（包括“晓漫”、“小曼”、“小慢”、“小蛮”、“小忙”等同音与近音词的嵌入向量）
  final Map<String, List<double>> _startWordPrototypes = {};

  static const Map<String, List<String>> _builtInPhoneticClusters = {
    'xiaoman': ['晓漫', '小曼', '小慢', '晓曼', '小蛮', '肖漫', '小忙', '小满', '筱漫', '小麦', '晓麦'],
    'huida': ['回答', '回大', '会大', '回话', '解答', '答复', '请回答'],
    'xinqiyige': ['新起一个', '新启一个', '重新开始', '起个新的', '新建会话'],
  };

  String? _cachedStartWord;
  String? _cachedEndWord;
  String? _cachedResetWord;

  TriggerMatcher({
    required this.settings,
    required this.embeddingService,
  });

  /// 自动生成开始词的同音与近音原型词簇
  List<String> generateStartWordVariants(String word) {
    final clean = stripPunctuation(word, all: true);
    if (clean.isEmpty) return [];

    final variants = <String>{clean};
    final py = _toPinyinClean(clean);

    if (_builtInPhoneticClusters.containsKey(py)) {
      variants.addAll(_builtInPhoneticClusters[py]!);
    }

    return variants.toList();
  }

  /// 预热并缓存当前配置关键词与多原型向量池的 Embedding 向量
  Future<void> warmUp() async {
    final start = settings.startWord.trim();
    final end = settings.endWord.trim();
    final reset = settings.resetWord.trim();

    if (_cachedStartWord != start || _startWordPrototypes.isEmpty) {
      if (start.isNotEmpty) {
        _startWordPrototypes.clear();
        final variants = generateStartWordVariants(start);
        for (final v in variants) {
          final emb = await _safeGetEmbedding(v);
          if (emb != null) {
            _startWordPrototypes[v] = emb;
          }
        }
        _startWordEmbedding = _startWordPrototypes[start] ?? (await _safeGetEmbedding(start));
        _cachedStartWord = start;
      }
    }

    if (_cachedEndWord != end || _endWordEmbedding == null) {
      if (end.isNotEmpty) {
        _endWordEmbedding = await _safeGetEmbedding(end);
        _cachedEndWord = end;
      }
    }

    if (_cachedResetWord != reset || _resetWordEmbedding == null) {
      if (reset.isNotEmpty) {
        _resetWordEmbedding = await _safeGetEmbedding(reset);
        _cachedResetWord = reset;
      }
    }
  }

  Future<List<double>?> _safeGetEmbedding(String text) async {
    try {
      return await embeddingService.getEmbedding(text);
    } catch (e) {
      // 容错处理
      return null;
    }
  }

  /// 归一化拼音（去除空格、声调、统一小写）
  String _toPinyinClean(String text) {
    if (text.isEmpty) return '';
    try {
      final py = PinyinHelper.getPinyin(text, separator: '', format: PinyinFormat.WITHOUT_TONE);
      return py.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    } catch (_) {
      return text.toLowerCase();
    }
  }

  /// 检测给定的候选短语是否匹配开始词（级联双引擎：先毫秒级拼音，后多原型向量兜底）
  Future<TriggerMatchResult> checkStartWord(String candidate) async {
    // 1. 级联 Stage 1: 极速字面与拼音切片匹配 (0ms)
    final match = await _matchSpecific(candidate, settings.startWord, _startWordEmbedding, TriggerType.start);
    if (match.isMatched) {
      return match;
    }

    // 2. 级联 Stage 2: 多原型向量余弦匹配 (当 Stage 1 遇到 ASR 复杂近音/前后鼻音错写时兜底)
    if (_startWordPrototypes.isNotEmpty) {
      final candClean = stripPunctuation(candidate);
      if (candClean.isNotEmpty) {
        final targetLen = settings.startWord.length;
        final maxSliceLen = (targetLen + 2).clamp(1, candClean.length);

        for (int len = targetLen.clamp(1, candClean.length); len <= maxSliceLen; len++) {
          final slice = candClean.substring(0, len);
          final sliceClean = stripPunctuation(slice, all: true);
          if (sliceClean.isEmpty) continue;

          final sliceEmb = await _safeGetEmbedding(sliceClean);
          if (sliceEmb != null) {
            double bestSim = 0.0;
            String bestPrototype = '';

            for (final entry in _startWordPrototypes.entries) {
              final sim = VectorMath.cosineSimilarity(sliceEmb, entry.value);
              if (sim > bestSim) {
                bestSim = sim;
                bestPrototype = entry.key;
              }
            }

            if (bestSim >= settings.similarityThreshold) {
              return TriggerMatchResult(
                type: TriggerType.start,
                matchedText: slice,
                startIndex: 0,
                endIndex: len,
                similarity: bestSim,
                method: 'semantic_vector_prototype ($bestPrototype)',
              );
            }
          }
        }
      }
    }

    return TriggerMatchResult.none();
  }

  /// 检测给定的候选短语是否匹配结束词
  Future<TriggerMatchResult> checkEndWord(String candidate) async {
    return _matchSpecific(candidate, settings.endWord, _endWordEmbedding, TriggerType.end);
  }

  /// 检测给定的候选短语是否匹配重置会话词
  Future<TriggerMatchResult> checkResetWord(String candidate) async {
    return _matchSpecific(candidate, settings.resetWord, _resetWordEmbedding, TriggerType.reset);
  }

  /// 去除字符串首尾或全量常见中英文标点符号
  String stripPunctuation(String text, {bool all = false}) {
    if (all) {
      return text.replaceAll(RegExp(r'[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+'), '');
    }
    return text.replaceAll(RegExp(r'^[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+|[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+$'), '').trim();
  }

  /// 待机极速唤醒词存在性初筛（耗时 <0.01ms）：
  /// 在待机监听时，极速判定传入语句是否具备唤醒词或控制指令的组合特征。
  /// 若完全无关（如环境杂谈“今天吃什么”、“这个代码怎么跑起来”），立即阻断后续所有耗性能的向量检索与模型调用，待机消耗降为零。
  bool quickWakePlausibilityCheck(String text) {
    final clean = stripPunctuation(text, all: true);
    if (clean.isEmpty) return false;

    // 0. 直接包含用户配置的开始词或重置词
    if (clean.contains(settings.startWord) || clean.contains(settings.resetWord)) {
      return true;
    }

    // 1. 开始词字面组合粗筛（前缀音 + 后缀音组合，避免单字如“起”、“小”误触发）
    const prefixChars = {'小', '晓', '肖', '筱', '消', '校', '孝'};
    const suffixChars = {'曼', '漫', '慢', '蛮', '忙', '满', '猫', '南', '门', '埋', '麦'};
    bool hasPrefix = false;
    bool hasSuffix = false;
    for (int i = 0; i < clean.length; i++) {
      final ch = clean[i];
      if (prefixChars.contains(ch)) hasPrefix = true;
      if (suffixChars.contains(ch)) hasSuffix = true;
    }
    if (hasPrefix && hasSuffix) return true;

    // 2. 控制词短语初筛（避免单个字“起”误触发）
    if (clean.contains('新起') ||
        clean.contains('重新') ||
        clean.contains('新建') ||
        clean.contains('新启')) {
      return true;
    }

    // 3. 拼音特征粗筛：包含 xiaoman, xiaomang, xiaonan, xiaomen, xiaomao, xiaomai, xinqi, chongxin
    final py = _toPinyinClean(clean);
    if (py.contains('xiaoman') ||
        py.contains('xiaomang') ||
        py.contains('xiaonan') ||
        py.contains('xiaomen') ||
        py.contains('xiaomao') ||
        py.contains('xiaomai') ||
        py.contains('xinqi') ||
        py.contains('chongxin') ||
        py.contains('xinjian')) {
      return true;
    }

    final startPy = _toPinyinClean(settings.startWord);
    if (startPy.isNotEmpty && py.contains(startPy)) {
      return true;
    }

    return false;
  }

  /// 针对待机状态：综合扫描当前短语中是否包含新起会话词或开始词
  Future<TriggerMatchResult> checkWakeAndControlWords(String candidate) async {
    final clean = candidate.trim();
    if (clean.isEmpty) {
      return TriggerMatchResult.none();
    }

    // 优先检测是否是重置会话词（如“新起一个”或“新起一个。”）
    final resetResult = await checkResetWord(clean);
    if (resetResult.isMatched) {
      return resetResult;
    }

    // 其次检测是否是开始词（如“晓漫”或“小曼”）
    final startResult = await checkStartWord(clean);
    if (startResult.isMatched) {
      return startResult;
    }

    return TriggerMatchResult.none();
  }

  /// 检查是否是一句完整包含开始词与结束词的单次提问（如“小曼 xxx 回答。”）
  Future<ExtractedCommand?> extractOneShotCommand(String sentence) async {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) return null;

    final startMatch = await checkStartWord(trimmed);
    if (!startMatch.isMatched || startMatch.endIndex <= 0) return null;

    final afterStart = trimmed.substring(startMatch.endIndex).trim();
    if (afterStart.isEmpty) return null;

    final endMatch = await checkEndWord(afterStart);
    if (!endMatch.isMatched) return null;

    final prompt = stripEndWord(afterStart);
    if (prompt.isEmpty) return null;

    return ExtractedCommand(
      startWord: startMatch.matchedText,
      promptContent: prompt,
      endWord: endMatch.matchedText,
    );
  }

  Future<TriggerMatchResult> _matchSpecific(
    String candidate,
    String targetWord,
    List<double>? targetEmbedding,
    TriggerType type,
  ) async {
    final candClean = candidate.trim();
    final targetClean = targetWord.trim();
    if (candClean.isEmpty || targetClean.isEmpty) {
      return TriggerMatchResult.none();
    }

    // 0. 去除标点后对比（直接说出单个词如“新起一个。”、“回答。”）
    final candNoPunct = stripPunctuation(candClean, all: true);
    final targetNoPunct = stripPunctuation(targetClean, all: true);
    if (candNoPunct.isNotEmpty && candNoPunct == targetNoPunct) {
      return TriggerMatchResult(
        type: type,
        matchedText: candClean,
        startIndex: 0,
        endIndex: candClean.length,
        similarity: 1.0,
        method: 'exact',
      );
    }

    // 1. L1 精确字面子串匹配
    final exactIdx = candClean.indexOf(targetClean);
    if (exactIdx != -1) {
      return TriggerMatchResult(
        type: type,
        matchedText: targetClean,
        startIndex: exactIdx,
        endIndex: exactIdx + targetClean.length,
        similarity: 1.0,
        method: 'exact',
      );
    }

    // 2. L1 拼音同音容错匹配（针对“小曼” vs “晓漫”，精确定位切片起始和结束位置）
    final targetPy = _toPinyinClean(targetClean);
    if (targetPy.isNotEmpty) {
      final slice = _findPinyinSlice(candClean, targetPy, targetClean.length);
      if (slice != null) {
        return TriggerMatchResult(
          type: type,
          matchedText: slice['text'] as String,
          startIndex: slice['start'] as int,
          endIndex: slice['end'] as int,
          similarity: 0.95,
          method: 'pinyin',
        );
      }

      // 2.5 L1.5 极速拼音模糊近音匹配（前后鼻音、Levenshtein 编辑距离，耗时 <0.01ms，无需调用任何向量 API）
      final fuzzySlice = _findFuzzyPinyinSlice(candClean, targetPy, targetClean.length);
      if (fuzzySlice != null) {
        return TriggerMatchResult(
          type: type,
          matchedText: fuzzySlice['text'] as String,
          startIndex: fuzzySlice['start'] as int,
          endIndex: fuzzySlice['end'] as int,
          similarity: fuzzySlice['similarity'] as double,
          method: fuzzySlice['method'] as String,
        );
      }
    }

    // 3. L2 向量语义余弦相似度匹配（模糊语义与同义词）
    if (targetEmbedding != null) {
      // 3.1 尝试去除标点后整句相似度
      try {
        final candEmbedding = await embeddingService.getEmbedding(
          candNoPunct.isNotEmpty ? candNoPunct : candClean,
        );
        final sim = VectorMath.cosineSimilarity(candEmbedding, targetEmbedding);
        if (sim >= settings.similarityThreshold) {
          return TriggerMatchResult(
            type: type,
            matchedText: candClean,
            startIndex: 0,
            endIndex: candClean.length,
            similarity: sim,
            method: 'semantic_vector',
          );
        }
      } catch (_) {}

      // 3.2 对于长句中的结束词（如末尾是“请解答”、“请回复”、“答复一下”等），对末尾窗口进行向量检索
      if (type == TriggerType.end && candNoPunct.length > targetNoPunct.length) {
        final tailLen = (targetNoPunct.length + 2).clamp(2, candNoPunct.length);
        final tailWord = candNoPunct.substring(candNoPunct.length - tailLen);
        try {
          final tailEmbedding = await embeddingService.getEmbedding(tailWord);
          final sim = VectorMath.cosineSimilarity(tailEmbedding, targetEmbedding);
          if (sim >= settings.similarityThreshold) {
            return TriggerMatchResult(
              type: type,
              matchedText: tailWord,
              startIndex: candClean.length - tailLen,
              endIndex: candClean.length,
              similarity: sim,
              method: 'semantic_vector',
            );
          }
        } catch (_) {}
      }
    }

    return TriggerMatchResult.none();
  }

  /// 扫描并在 candidate 中精确定位拼音匹配的最小子串切片
  Map<String, dynamic>? _findPinyinSlice(String text, String targetPy, int targetCharLength) {
    if (text.isEmpty || targetPy.isEmpty) return null;

    final maxLen = (targetCharLength + 3).clamp(1, text.length);
    for (int i = 0; i < text.length; i++) {
      for (int len = 1; len <= maxLen && i + len <= text.length; len++) {
        final sub = text.substring(i, i + len);
        final cleanSub = stripPunctuation(sub, all: true);
        if (cleanSub.isEmpty) continue;
        if (_toPinyinClean(cleanSub) == targetPy) {
          return {
            'text': sub,
            'start': i,
            'end': i + len,
          };
        }
      }
    }
    return null;
  }

  /// 归一化前后鼻音 (ang -> an, eng -> en, ing -> in, ong -> on)
  static String _normalizeNasal(String py) {
    return py
        .replaceAll('ang', 'an')
        .replaceAll('eng', 'en')
        .replaceAll('ing', 'in')
        .replaceAll('ong', 'on');
  }

  /// 极速 Levenshtein 字符编辑距离（整数动态规划，耗时 <0.005ms）
  static int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> v0 = List<int>.generate(t.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < t.length; j++) {
        final cost = (s.codeUnitAt(i) == t.codeUnitAt(j)) ? 0 : 1;
        v1[j + 1] = math.min(v1[j] + 1, math.min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j <= t.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v0[t.length];
  }

  /// 扫描并在 candidate 中模糊匹配拼音切片（支持前后鼻音容错与编辑距离 <= 1，耗时 <0.01ms）
  Map<String, dynamic>? _findFuzzyPinyinSlice(String text, String targetPy, int targetCharLength) {
    if (text.isEmpty || targetPy.isEmpty) return null;

    final normTargetPy = _normalizeNasal(targetPy);
    final maxLen = (targetCharLength + 3).clamp(1, text.length);

    for (int i = 0; i < text.length; i++) {
      for (int len = targetCharLength.clamp(1, text.length); len <= maxLen && i + len <= text.length; len++) {
        final sub = text.substring(i, i + len);
        final cleanSub = stripPunctuation(sub, all: true);
        if (cleanSub.isEmpty) continue;

        final subPy = _toPinyinClean(cleanSub);
        if (subPy.isEmpty) continue;

        // 1. 鼻音归一化精确匹配 (如 xiaomang -> xiaoman)
        final normSubPy = _normalizeNasal(subPy);
        if (normSubPy == normTargetPy) {
          return {
            'text': sub,
            'start': i,
            'end': i + len,
            'similarity': 0.93,
            'method': 'fuzzy_pinyin_nasal',
          };
        }

        // 2. 拼音 Levenshtein 编辑距离容错匹配 (距离 <= 1)
        final dist = _levenshtein(normSubPy, normTargetPy);
        if (dist <= 1) {
          return {
            'text': sub,
            'start': i,
            'end': i + len,
            'similarity': 0.88,
            'method': 'fuzzy_pinyin_edit_dist',
          };
        }
      }
    }
    return null;
  }

  /// 剥离尾部匹配到的结束词与所有标点符号，提取纯净提问内容
  String stripEndWord(String fullText) {
    String text = fullText.trim();
    final end = settings.endWord.trim();
    if (end.isEmpty) return stripPunctuation(text);

    // 1. 去除末尾所有标点符号
    text = stripPunctuation(text);

    // 2. 精确字面结尾剥离
    if (text.endsWith(end)) {
      text = text.substring(0, text.length - end.length);
    } else {
      // 3. 拼音同音与前后鼻音尾部剥离（如“回答。”、“回大”、“解答”）
      final endPy = _toPinyinClean(end);
      final normEndPy = _normalizeNasal(endPy);
      final maxTailLen = (end.length + 2).clamp(1, text.length);
      for (int len = end.length; len <= maxTailLen && text.length >= len; len++) {
        final tail = text.substring(text.length - len);
        final tailClean = stripPunctuation(tail, all: true);
        final tailPy = _toPinyinClean(tailClean);
        if (tailPy == endPy || _normalizeNasal(tailPy) == normEndPy) {
          text = text.substring(0, text.length - len);
          break;
        }
      }
    }

    return stripPunctuation(text);
  }
}
