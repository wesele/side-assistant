export '../../models/trigger_result.dart';
import '../../ports/trigger_matcher_port.dart';
import '../../models/app_settings.dart';
import 'phonetic_matcher_helper.dart';

class TriggerMatcher implements TriggerMatcherPort {
  final AppSettings settings;
  

  /// 全量标点/空白正则（与 [stripPunctuation] 的 all 模式保持一致），
  /// 供静态辅助方法复用。
  static final RegExp _punctuationAll = RegExp(
    r'[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+',
  );
  static final RegExp _punctuationEdge = RegExp(
    r'^[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+|[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+$',
  );

  /// 静态去除全量中英文标点与空白
  static String stripAllPunctuation(String text) {
    return text.replaceAll(_punctuationAll, '').trim();
  }

  
  
  

  /// 开始词多原型向量池（包括“晓漫”、“小曼”、“小慢”、“小蛮”、“小忙”等同音与近音词的嵌入向量）
  

  /// 结束词多原型向量池（包括“回答”、“回话”、“请解答”、“答复一下”等同音与近义收尾词的嵌入向量）
  

  /// 新起会话词多原型向量池（包括“新起一个”、“重新开始”、“新建会话”等同义说法）
  

  /// 内置同音/近音/近义词簇（以拼音为键）。
  /// 开始词、结束词各自按自身拼音命中对应词簇，从而自动获得 ASR 误识容错，
  /// 无需用户手工配置同义词。
  static const Map<String, List<String>> _builtInPhoneticClusters = {
    'xiaoman': ['晓漫', '小曼', '小慢', '晓曼', '小蛮', '肖漫', '小忙', '小满', '筱漫', '小麦', '晓麦'],
    // 结束词“回答”的兼容簇：前半为同音/近音误识（声学层），后半为语义等价的收尾指令（语义层）
    'huida': [
      '回答', '回大', '会大', '会答', '回打', '回哒', '回搭', '回答我', '回话',
      '请回答', '请解答', '请答复', '请回复', '作答',
      '回答一下', '解答一下', '答复一下', '回答吧',
    ],
    'xinqiyige': [
      '新起一个', '新启一个', '重新开始', '起个新的', '新建会话', '重新说',
      '新起一个会话', '换个话题', '重开一个', '新开一个',
    ],
  };

  
  
  

  /// 结束词兼容别名缓存（同音/近音/近义收尾词，不含结束词本身），按结束词变化失效
  List<String>? _cachedEndWordAliases;
  String? _cachedEndWordAliasesFor;

  /// 新起会话词兼容别名缓存，按配置变化失效
  List<String>? _cachedResetWordAliases;
  String? _cachedResetWordAliasesFor;

  /// 当前配置的多个开始词 / 结束词 / 新起会话词（支持设置里用分号配置多个）。
  ///
  /// 约定：列表第一个词是“主词”，用于日志与兼容旧行为的展示；匹配时全部参与。
  @override
  List<String> get startWords => _nonEmpty(settings.startWords);
  List<String> get endWords => _nonEmpty(settings.endWords);
  List<String> get resetWords => _nonEmpty(settings.resetWords);

  static List<String> _nonEmpty(List<String> words) {
    final result = <String>[];
    for (final w in words) {
      if (w.replaceAll(_punctuationAll, '').isNotEmpty) result.add(w);
    }
    return result;
  }

  /// 取主词（列表首项）；没有配置时回退到默认值，避免匹配逻辑出现空词。
  String get primaryStartWord =>
      startWords.isNotEmpty ? startWords.first : settings.startWord;
  String get primaryEndWord =>
      endWords.isNotEmpty ? endWords.first : settings.endWord;
  String get primaryResetWord =>
      resetWords.isNotEmpty ? resetWords.first : settings.resetWord;


  @override
  Future<bool> checkExitContinuousWord(String candidate) async {
    final clean = stripPunctuation(candidate, all: true).trim();
    if (clean.isEmpty) return false;

    String remaining = clean;
    final startMatch = await checkStartWord(remaining);
    if (startMatch.isMatched && startMatch.endIndex > 0) {
      remaining = remaining.substring(startMatch.endIndex).trim();
      remaining = stripPunctuation(remaining, all: true).trim();
    }

    remaining = stripEndWord(remaining).trim();
    remaining = stripPunctuation(remaining, all: true).trim();

    if (remaining.isEmpty) return false;

    const modalParticles = {'吧', '啦', '了', '啊', '呗', '呀', '哦', '哈'};

    final allowedWords = <String>{};
    for (final exitWord in settings.exitContinuousWords) {
      final cleanExit = stripPunctuation(exitWord, all: true).trim();
      if (cleanExit.isEmpty) continue;
      allowedWords.add(cleanExit);
      if (cleanExit == '结束对话') {
        allowedWords.addAll(['结束对话', '停止对话', '退出对话']);
      }
    }

    for (final exitWord in allowedWords) {
      if (remaining == exitWord) return true;
      if (remaining.startsWith(exitWord) && remaining.length == exitWord.length + 1) {
        final lastChar = remaining.substring(exitWord.length);
        if (modalParticles.contains(lastChar)) return true;
      }
    }
    return false;
  }

  TriggerMatcher({required this.settings});

  /// 自动生成开始词的同音与近音原型词簇
  List<String> generateStartWordVariants(String word) {
    return _generateWordVariants(word);
  }

  /// 自动生成结束词的同音、近音与近义（收尾指令）原型词簇
  List<String> generateEndWordVariants(String word) {
    return _generateWordVariants(word);
  }

  /// 自动生成新起会话词的同音、近音与近义原型词簇
  List<String> generateResetWordVariants(String word) {
    return _generateWordVariants(word);
  }

  /// 按拼音命中内置词簇，生成某个触发词的全部兼容变体（含自身）
  List<String> _generateWordVariants(String word) {
    final clean = stripPunctuation(word, all: true);
    if (clean.isEmpty) return [];

    final variants = <String>{clean};
    final py = _toPinyinClean(clean);

    if (_builtInPhoneticClusters.containsKey(py)) {
      variants.addAll(_builtInPhoneticClusters[py]!);
    }

    return variants.toList();
  }

  List<String> _buildAliases(List<String> words) {
    final configured = <String>{
      for (final w in words) ...[w, stripPunctuation(w, all: true)],
    };
    final variants = <String>{};
    for (final word in words) {
      variants.addAll(_generateWordVariants(word));
    }
    variants.removeAll(configured);
    return variants.toList();
  }

  /// 当前生效的结束词兼容别名（不含结束词本身），用于字面/拼音层的离线容错匹配。
  ///
  /// 配置多个结束词时，所有词的变体合并去重，并排除全部配置词本身。
  List<String> get endWordAliases {
    final end = settings.endWord.trim();
    if (_cachedEndWordAliasesFor == end && _cachedEndWordAliases != null) {
      return _cachedEndWordAliases!;
    }
    final result = _buildAliases(endWords);
    _cachedEndWordAliases = result;
    _cachedEndWordAliasesFor = end;
    return result;
  }

  /// 当前生效的新起会话词兼容别名（不含配置词本身）。
  List<String> get resetWordAliases {
    final reset = settings.resetWord.trim();
    if (_cachedResetWordAliasesFor == reset && _cachedResetWordAliases != null) {
      return _cachedResetWordAliases!;
    }
    final result = _buildAliases(resetWords);
    _cachedResetWordAliases = result;
    _cachedResetWordAliasesFor = reset;
    return result;
  }

  

  /// 预热并缓存当前配置关键词与多原型向量池的 Embedding 向量
    @override
  Future<void> warmUp() async {
    // 纯离线拼音与字面匹配，零远程网络/嵌入向量预热开销
  }

  

  /// 归一化拼音（去除空格、声调、统一小写）
  String _toPinyinClean(String text) => PhoneticMatcherHelper.toPinyinClean(text);

  /// 检测给定的候选短语是否匹配开始词（级联双引擎：先毫秒级拼音，后多原型向量兜底）
  ///
  /// 支持配置多个开始词：逐个词跑同一套级联，取相似度最高的一次命中。
  @override
  Future<TriggerMatchResult> checkStartWord(String candidate) async {
    TriggerMatchResult best = TriggerMatchResult.none();
    for (final word in _wordsOrFallback(startWords, settings.startWord)) {
      final match = await _checkStartWordSingle(candidate, word);
      if (match.isMatched &&
          (best.type == TriggerType.none || match.similarity > best.similarity)) {
        best = match;
      }
    }
    return best;
  }

  /// 单开始词的匹配（原逻辑）。
  Future<TriggerMatchResult> _checkStartWordSingle(
    String candidate,
    String word,
  ) async {
    // 1. 级联 Stage 1: 极速字面与拼音切片匹配 (0ms)
    final match = await _matchSpecific(
      candidate,
      word,
      null,
      TriggerType.start,
    );
    if (match.isMatched) {
      return match;
    }

    return TriggerMatchResult.none();
  }

  /// 配置词列表为空时，回退到设置里的原始值，保证默认行为不变。
  List<String> _wordsOrFallback(List<String> words, String raw) {
    if (words.isNotEmpty) return words;
    final fallback = raw.trim();
    return fallback.isEmpty ? const <String>[] : <String>[fallback];
  }

  /// 检测给定的候选短语是否匹配结束词
  ///
  /// 采用与开始词一致的三段级联，且对结束词额外加入「内置兼容词簇」这一离线保底层：
  ///  1) 精确字面 / 拼音同音 / 前后鼻音模糊 / 单原型向量（_matchSpecific）
  ///  2) 内置同音·近义收尾词簇的字面与拼音匹配（不依赖向量服务，断网也生效）
  ///  3) 多原型向量余弦兜底（ASR 把收尾词识别成差异很大的说法时的语义兜底）
  @override
  Future<TriggerMatchResult> checkEndWord(String candidate) async {
    // 1. 内置兼容词簇优先：更具体、更长的收尾词（如“请回答”“请解答”）先命中，
    //    避免随后主结束词“回答”在更靠后的位置命中、把前面的“请”字残留在提问里。
    final aliasMatch = _matchAliasCluster(candidate, endWordAliases);
    if (aliasMatch.isMatched) {
      return aliasMatch;
    }

    // 2. 各配置结束词的主匹配（精确字面 / 拼音同音 / 前后鼻音模糊 / 单原型向量）
    TriggerMatchResult best = TriggerMatchResult.none();
    for (final word in _wordsOrFallback(endWords, settings.endWord)) {
      final match = await _matchSpecific(
        candidate,
        word,
        null,
        TriggerType.end,
      );
      if (match.isMatched &&
          (best.type == TriggerType.none ||
              match.similarity > best.similarity)) {
        best = match;
      }
    }
    if (best.isMatched) return best;

    return TriggerMatchResult.none();
  }

  /// 检测给定的候选短语是否匹配新起会话词。
  ///
  /// 与开始词一致的三段级联（精确/拼音 → 内置兼容词簇 → 多原型语义兜底），
  /// 因此“新起一个”被识别成“新启一个”“重新开始”“起个新的”也能命中。
  @override
  Future<TriggerMatchResult> checkResetWord(String candidate) async {
    // 1. 内置同义/同音词簇（离线也生效）
    final aliasMatch = _matchResetAliasCluster(candidate, resetWordAliases);
    if (aliasMatch.isMatched) {
      return aliasMatch;
    }

    // 2. 各配置词的精确/拼音/单原型匹配
    TriggerMatchResult best = TriggerMatchResult.none();
    for (final word in _wordsOrFallback(resetWords, settings.resetWord)) {
      final match = await _matchSpecific(
        candidate,
        word,
        null,
        TriggerType.reset,
      );
      if (match.isMatched &&
          (best.type == TriggerType.none ||
              match.similarity > best.similarity)) {
        best = match;
      }
    }
    if (best.isMatched) return best;

    return TriggerMatchResult.none();
  }

  /// 在候选语句中查找任一内置新起会话别名。
  ///
  /// 与结束词不同，重置指令不一定在句尾（“新起一个，我们聊点别的”），
  /// 因此这里扫描整句，取覆盖最靠后的一次命中。
  ///
  /// 但“重新开始”这类通用短语容易出现在长句中间（“我们重新开始这个话题吧”），
  /// 所以命中位置不在句首/句尾附近时，要求候选句本身很短才认。
  TriggerMatchResult _matchResetAliasCluster(
    String candidate,
    List<String> aliases,
  ) {
    final raw = candidate.trim();
    if (raw.isEmpty || aliases.isEmpty) return TriggerMatchResult.none();

    // 重置是“整句指令”，不是句中出现就算：
    // 命中词之外剩余的内容太多时（“我们重新开始这个话题吧不然跑不通”），
    // 说明用户是在正常对话里用到这个词，不应该清空上下文。
    const int maxResidualChars = 6;
    bool isCleanHit(int start, int end) {
      final before = stripPunctuation(raw.substring(0, start), all: true);
      final after = stripPunctuation(raw.substring(end), all: true);
      return before.length + after.length <= maxResidualChars;
    }

    TriggerMatchResult best = TriggerMatchResult.none();
    bool isBetter(int start) =>
        best.type == TriggerType.none || start >= best.startIndex;

    for (final alias in aliases) {
      if (alias.isEmpty) continue;
      final idx = raw.lastIndexOf(alias);
      if (idx == -1 || !isBetter(idx)) continue;
      if (!isCleanHit(idx, idx + alias.length)) continue;
      best = TriggerMatchResult(
        type: TriggerType.reset,
        matchedText: alias,
        startIndex: idx,
        endIndex: idx + alias.length,
        similarity: 1.0,
        method: 'alias_exact',
      );
    }

    for (final alias in aliases) {
      if (alias.isEmpty) continue;
      final aPy = _toPinyinClean(alias);
      if (aPy.isEmpty) continue;
      final slice = _findPinyinSlice(raw, aPy, alias.length, reverse: true) ??
          _findFuzzyPinyinSlice(raw, aPy, alias.length, reverse: true);
      if (slice == null) continue;
      final start = slice['start'] as int;
      final end = slice['end'] as int;
      if (!isBetter(start) || !isCleanHit(start, end)) continue;
      best = TriggerMatchResult(
        type: TriggerType.reset,
        matchedText: slice['text'] as String,
        startIndex: start,
        endIndex: end,
        similarity: (slice['similarity'] as double?) ?? 0.95,
        method: (slice['method'] as String?) ?? 'alias_pinyin',
      );
    }

    return best;
  }

  /// 句尾多原型向量兜底：只扫描句尾窗口，与兼容词簇的原型向量逐一比较，取最高相似度。
  

  /// 在候选语句中查找任一内置兼容别名（同音/近音/近义收尾词）。
  ///
  /// 收尾指令必然落在句末，因此这里**只在句尾附近确认**（命中词后最多允许 1 个字的尾随杂音，
  /// 例如 ASR 多听出的“啊/吧/。”），从而避免把句中出现的“解答一下…”等内容误当成结束词。
  /// 命中时取位置最靠后的一次。
  TriggerMatchResult _matchAliasCluster(String candidate, List<String> aliases) {
    final candClean = candidate.trim();
    if (candClean.isEmpty || aliases.isEmpty) {
      return TriggerMatchResult.none();
    }

    const int maxTrailing = 3;
    TriggerMatchResult best = TriggerMatchResult.none();

    bool isBetter(int startIndex) => !best.isMatched || startIndex > best.startIndex;

    for (final alias in aliases) {
      final a = alias.trim();
      if (a.isEmpty) continue;

      // 2.1 字面子串（取最后一次出现）
      final idx = candClean.lastIndexOf(a);
      if (idx != -1) {
        if (candClean.length - (idx + a.length) <= maxTrailing && isBetter(idx)) {
          best = TriggerMatchResult(
            type: TriggerType.end,
            matchedText: a,
            startIndex: idx,
            endIndex: idx + a.length,
            similarity: 0.99,
            method: 'alias_exact',
          );
        }
        continue;
      }

      // 2.2 拼音同音 / 前后鼻音与编辑距离模糊容错
      final aPy = _toPinyinClean(a);
      if (aPy.isEmpty) continue;
      final slice = _findPinyinSlice(candClean, aPy, a.length, reverse: true) ??
          _findFuzzyPinyinSlice(candClean, aPy, a.length, reverse: true);
      if (slice == null) continue;

      final start = slice['start'] as int;
      final end = slice['end'] as int;
      if (candClean.length - end > maxTrailing || !isBetter(start)) continue;

      best = TriggerMatchResult(
        type: TriggerType.end,
        matchedText: slice['text'] as String,
        startIndex: start,
        endIndex: end,
        similarity: (slice['similarity'] as double?) ?? 0.95,
        method: (slice['method'] as String?) ?? 'alias_pinyin',
      );
    }

    return best;
  }

  /// 去除字符串首尾或全量常见中英文标点符号
  @override
  String stripPunctuation(String text, {bool all = false}) {
    if (all) {
      return text.replaceAll(_punctuationAll, '');
    }
    return text.replaceAll(_punctuationEdge, '').trim();
  }

  /// 待机极速唤醒词存在性初筛（耗时 <0.01ms）：
  /// 在待机监听时，极速判定传入语句是否具备唤醒词或控制指令的组合特征。
  /// 若完全无关（如环境杂谈“今天吃什么”、“这个代码怎么跑起来”），立即阻断后续所有耗性能的向量检索与模型调用，待机消耗降为零。
  bool quickWakePlausibilityCheck(String text) {
    final clean = stripPunctuation(text, all: true);
    if (clean.isEmpty) return false;

    final startList = _wordsOrFallback(startWords, settings.startWord);
    final resetList = _wordsOrFallback(resetWords, settings.resetWord);

    // 0. 直接包含用户配置的开始词或新起会话词
    for (final word in [...startList, ...resetList]) {
      final w = stripPunctuation(word, all: true);
      if (w.isNotEmpty && clean.contains(w)) return true;
    }

    // 1. 通用唤醒词粗筛：首字 + 尾字同时出现，或拼音包含。
    //    这样用户把开始词改成“小助手”“你好小秘”等也能正常唤醒。
    for (final word in startList) {
      final startClean = stripPunctuation(word, all: true);
      if (startClean.isEmpty) continue;
      if (clean.contains(startClean)) return true;
      if (startClean.length >= 2) {
        final first = startClean[0];
        final last = startClean[startClean.length - 1];
        if (clean.contains(first) && clean.contains(last)) return true;
      }
      final startPy = _toPinyinClean(startClean);
      if (startPy.isNotEmpty && _toPinyinClean(clean).contains(startPy)) {
        return true;
      }
    }

    // 2. 默认“晓漫”的扩展同音字粗筛（保留原有行为，覆盖拼音归一化覆盖不到的写法）
    if (startList.any((w) => stripPunctuation(w, all: true) == '晓漫')) {
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
    }

    // 3. 控制词短语初筛（避免单个字“起”误触发）
    if (clean.contains('新起') ||
        clean.contains('重新') ||
        clean.contains('新建') ||
        clean.contains('新启')) {
      return true;
    }

    // 4. 拼音特征粗筛：包含 xiaoman, xiaomang, xiaonan, xiaomen, xiaomao, xiaomai, xinqi, chongxin
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
  @override
  Future<ExtractedCommand?> extractOneShotCommand(String sentence) async {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) return null;

    final startMatch = await checkStartWord(trimmed);
    if (!startMatch.isMatched || startMatch.endIndex <= 0) return null;

    final afterStart = trimmed.substring(startMatch.endIndex).trim();
    if (afterStart.isEmpty) return null;

    final endMatch = await checkEndWord(afterStart);
    if (!endMatch.isMatched) return null;

    // 截取结束词之前的内容，丢弃结束词本身及后续任何内容
    String prompt = '';
    if (endMatch.startIndex >= 0 && endMatch.startIndex <= afterStart.length) {
      prompt = stripPunctuation(afterStart.substring(0, endMatch.startIndex));
    } else {
      prompt = stripEndWord(afterStart);
    }
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

    final isEnd = type == TriggerType.end;

    // 结束词只允许落在句尾：命中词后最多容忍 3 个字的尾随杂音（如“啊/吧/一起消”）。
    // 这是为了避免“帮我解答一下我的疑惑”这类句子在句中被误判为结束。
    const int maxTrailingForEnd = 3;
    bool isAtTail(int endIndex, String text) =>
        !isEnd || text.length - endIndex <= maxTrailingForEnd;

    // 1. L1 精确字面子串匹配（结束词优先匹配倒数最后一个）
    final exactIdx = isEnd ? candClean.lastIndexOf(targetClean) : candClean.indexOf(targetClean);
    if (exactIdx != -1 && isAtTail(exactIdx + targetClean.length, candClean)) {
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
      final slice = _findPinyinSlice(candClean, targetPy, targetClean.length, reverse: isEnd);
      if (slice != null && isAtTail(slice['end'] as int, candClean)) {
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
      final fuzzySlice = _findFuzzyPinyinSlice(candClean, targetPy, targetClean.length, reverse: isEnd);
      if (fuzzySlice != null && isAtTail(fuzzySlice['end'] as int, candClean)) {
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

    return TriggerMatchResult.none();
  }

  /// 扫描并在 candidate 中精确定位拼音匹配的最小子串切片
  Map<String, dynamic>? _findPinyinSlice(
    String text,
    String targetPy,
    int targetCharLength, {
    bool reverse = false,
  }) =>
      PhoneticMatcherHelper.findPinyinSlice(
        text,
        targetPy,
        targetCharLength,
        reverse: reverse,
      );

  /// 扫描并在 candidate 中模糊匹配拼音切片（支持前后鼻音容错与编辑距离 <= 1）
  Map<String, dynamic>? _findFuzzyPinyinSlice(
    String text,
    String targetPy,
    int targetCharLength, {
    bool reverse = false,
  }) =>
      PhoneticMatcherHelper.findFuzzyPinyinSlice(
        text,
        targetPy,
        targetCharLength,
        reverse: reverse,
      );

  /// 剥离结束词（含内置同音/近义兼容词）与后续内容及所有标点符号，
  /// 提取纯净提问内容（精准丢弃结束词本身及后续多余输入）
  @override
  String stripEndWord(String fullText) {
    String text = fullText.trim();
    final ends = _wordsOrFallback(endWords, settings.endWord);
    if (ends.isEmpty) return stripPunctuation(text);

    // 1. 精确字面查找：所有配置结束词与内置兼容别名一起参与，取「覆盖最靠右」的一次命中
    //    （同位置重叠时取更长的词，如“请回答”优先于“回答”，避免残留“请”字）。
    final candidates = <String>{...ends, ...endWordAliases};
    int bestStart = -1;
    int bestEnd = -1;
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final i = text.lastIndexOf(c);
      if (i == -1) continue;
      final endIdx = i + c.length;
      if (endIdx > bestEnd || (endIdx == bestEnd && i < bestStart)) {
        bestStart = i;
        bestEnd = endIdx;
      }
    }
    if (bestStart != -1) {
      return stripPunctuation(text.substring(0, bestStart));
    }

    // 2. 拼音同音与前后鼻音模糊查找（如“回大”、“会大”等），从后往前定位并截取前部内容
    for (final end in ends) {
      final endPy = _toPinyinClean(end);
      if (endPy.isEmpty) continue;
      final slice = _findPinyinSlice(text, endPy, end.length, reverse: true) ??
          _findFuzzyPinyinSlice(text, endPy, end.length, reverse: true);
      if (slice != null) {
        final start = slice['start'] as int;
        return stripPunctuation(text.substring(0, start));
      }
    }

    // 2.5 别名拼音兜底（如“请解答”“答复一下”等被 ASR 写成近音字）
    for (final alias in endWordAliases) {
      final aliasPy = _toPinyinClean(alias);
      if (aliasPy.isEmpty) continue;
      final slice = _findPinyinSlice(text, aliasPy, alias.length, reverse: true);
      if (slice != null) {
        return stripPunctuation(text.substring(0, slice['start'] as int));
      }
    }

    // 3. 兜底回退：末尾标点去除
    return stripPunctuation(text);
  }
}
