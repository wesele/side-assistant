import 'package:lpinyin/lpinyin.dart';
import '../../ports/trigger_matcher_port.dart';

/// 语音转写文本处理工具：负责流式/离线两遍文本合并、回声拒识判定、外放回声剥离及触发词后文切片。
class TranscriptProcessor {
  static final RegExp _normPunctRegExp = RegExp(r'[。，、？！；：\s]');
  static final RegExp _whitespaceRegExp = RegExp(r'\s+');

  /// 选择流式文本与离线复检文本的最终版本。
  ///
  /// 优先采用“更完整”的那一份：离线结果通常包含整段话，因此只要它覆盖了
  /// 流式文本就直接替换；否则按重叠关系合并，避免丢失流式已经识别出的前半句。
  static String chooseFinalTranscript(String live, String finalText) {
    final a = live.trim();
    final b = finalText.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    if (a == b) return a;

    String norm(String s) => s.replaceAll(_normPunctRegExp, '').toLowerCase();
    final na = norm(a);
    final nb = norm(b);
    if (nb.contains(na)) return b;
    if (na.contains(nb)) return a;

    return mergeStreamingTranscript(a, b);
  }

  /// 合并流式识别文本：识别器每次给出的是「当前句」的累计结果。
  ///
  /// - 正常增长（新文本以旧文本为前缀）：直接替换为更完整的新文本；
  /// - 断句复位后的新片段（与旧文本无重叠）：接续追加，避免覆盖丢失前面的提问内容；
  /// - 识别回退（新文本是旧文本的前缀）：保留已有的更完整文本。
  static String mergeStreamingTranscript(String current, String incoming) {
    final a = current.trim();
    final b = incoming.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    if (a == b) return a;

    // 识别回退：新结果是旧的子前缀，保留更完整的旧文本
    if (a.startsWith(b)) return a;

    // 正常增长或含有重叠：以旧文本后缀与新文本前缀的最长公共片段进行拼接
    final maxOverlap = a.length < b.length ? a.length : b.length;
    for (int k = maxOverlap; k > 0; k--) {
      if (a.endsWith(b.substring(0, k))) {
        return a + b.substring(k);
      }
    }

    // 无任何重叠：视为断句后的新片段，接续累积
    return '$a $b';
  }

  /// 判断 [recognized] 是否只是助手刚外放的朗读内容被麦克风回采后又被识别出来的回声。
  static bool looksLikeAssistantEcho({
    required String recognized,
    required String recentlySpokenText,
    required TriggerMatcherPort triggerMatcher,
  }) {
    if (recentlySpokenText.isEmpty) return false;

    final normalizedRecognized =
        triggerMatcher.stripPunctuation(recognized, all: true);
    final normalizedSpoken =
        triggerMatcher.stripPunctuation(recentlySpokenText, all: true);
    if (normalizedRecognized.isEmpty || normalizedSpoken.isEmpty) return false;

    // 1) 整体包含：最常见的情形，回声就是原句的完整子串
    if (normalizedSpoken.contains(normalizedRecognized)) return true;

    // 2) 首/尾 4 字片段命中：容错 ASR 在句首句尾的少量误识
    if (normalizedRecognized.length >= 4) {
      final head = normalizedRecognized.substring(0, 4);
      final tail =
          normalizedRecognized.substring(normalizedRecognized.length - 4);
      if (normalizedSpoken.contains(head) || normalizedSpoken.contains(tail)) {
        return true;
      }
    }

    // 3) 同音/前后鼻音拼音层兜底（如外放“适合出门散步”被识别成“适合出门三步”）
    if (normalizedRecognized.length >= 3) {
      final recPy = _toPinyinTokens(normalizedRecognized);
      final spokenPy = _toPinyinTokens(normalizedSpoken);
      if (_containsSublist(spokenPy, recPy)) return true;
      if (recPy.length >= 4) {
        final headPy = recPy.sublist(0, 4);
        final tailPy = recPy.sublist(recPy.length - 4);
        if (_containsSublist(spokenPy, headPy) ||
            _containsSublist(spokenPy, tailPy)) {
          return true;
        }
      }
    }
    return false;
  }

  /// 从识别文本 [recognized] 中剥离属于助手外放朗读内容 [recentlySpokenText] 的回声片段，
  /// 返回真正由用户发出的非回声残余文本（如混音“量子力学是研究小曼微观粒子” -> “小曼”）。
  ///
  /// 规则：
  /// 1. 若整句（字面或同音拼音）完全是 [recentlySpokenText] 的连续子串（例如助手自己朗读
  ///    “晓漫已经帮你设好闹钟了”），直接剥离为空串 `''`，杜绝自激唤醒。
  /// 2. 否则扫描 [recognized] 中所有长度 >= 3 的连续片段（字面或同音拼音），凡在 [recentlySpokenText]
  ///    中连续出现的均标记为回声。
  /// 3. 对长度 == 2 的连续片段，若在 [recentlySpokenText] 中出现且本身不是受保护的唤醒/打断词，
  ///    同样标记为回声；最后清理夹在回声之间的孤立单字回声残片。
  static String stripAssistantEcho({
    required String recognized,
    required String recentlySpokenText,
    required TriggerMatcherPort triggerMatcher,
  }) {
    final normRec = triggerMatcher.stripPunctuation(recognized, all: true);
    if (normRec.isEmpty) return '';

    final normSpoken =
        triggerMatcher.stripPunctuation(recentlySpokenText, all: true);
    if (normSpoken.isEmpty) return normRec;

    // 1. 整句完全是外放内容的连续子串（含同音误识）-> 100% 纯回声
    if (normSpoken.contains(normRec)) return '';

    final recPy = _toPinyinTokens(normRec);
    final spokenPy = _toPinyinTokens(normSpoken);
    if (recPy.length == normRec.length &&
        spokenPy.isNotEmpty &&
        _containsSublist(spokenPy, recPy)) {
      return '';
    }

    final n = normRec.length;
    final isEcho = List<bool>.filled(n, false);

    // 2. 标记所有长度 >= 3 的连续字面或同音回声片段
    for (int i = 0; i <= n - 3; i++) {
      for (int len = n - i; len >= 3; len--) {
        final sub = normRec.substring(i, i + len);
        final matched = normSpoken.contains(sub) ||
            (recPy.length == n &&
                _containsSublist(spokenPy, recPy.sublist(i, i + len)));
        if (matched) {
          for (int k = i; k < i + len; k++) {
            isEcho[k] = true;
          }
          break;
        }
      }
    }

    // 3. 标记长度 == 2 的非唤醒/打断回声片段（如“今天小曼不错”里的“今天”和“不错”）
    final protectedPinyins = _buildProtectedBargeInPinyins(triggerMatcher);
    for (int i = 0; i <= n - 2; i++) {
      final sub = normRec.substring(i, i + 2);
      final subPy = recPy.length == n ? recPy.sublist(i, i + 2).join() : '';
      if (_isProtectedBargeInSpan(sub, subPy, protectedPinyins)) {
        continue;
      }
      final matched = normSpoken.contains(sub) ||
          (recPy.length == n &&
              _containsSublist(spokenPy, recPy.sublist(i, i + 2)));
      if (matched) {
        isEcho[i] = true;
        isEcho[i + 1] = true;
      }
    }

    // 4. 清理被回声包围（或在首尾孤立）的 1 字回声残片（唤醒词至少 2 字，孤立单字不可能是唤醒词）
    for (int i = 0; i < n; i++) {
      if (isEcho[i]) continue;
      final leftEcho = (i == 0) || isEcho[i - 1];
      final rightEcho = (i == n - 1) || isEcho[i + 1];
      if (leftEcho && rightEcho && normSpoken.contains(normRec[i])) {
        isEcho[i] = true;
      }
    }

    final buffer = StringBuffer();
    for (int i = 0; i < n; i++) {
      if (!isEcho[i]) {
        buffer.write(normRec[i]);
      }
    }
    return buffer.toString();
  }

  static Set<String> _buildProtectedBargeInPinyins(
    TriggerMatcherPort triggerMatcher,
  ) {
    final set = <String>{
      'xiaoman',
      'xiaomai',
      'xiaomao',
      'xiaomen',
      'xiaonan',
      'tingzhi',
      'zanting',
    };
    for (final w in triggerMatcher.startWords) {
      final py = _toPinyinTokens(w).join();
      if (py.isNotEmpty) set.add(py);
    }
    return set;
  }

  static bool _isProtectedBargeInSpan(
    String sub,
    String subPy,
    Set<String> protectedPinyins,
  ) {
    if (sub == '停止' || sub == '暂停' || sub == '小曼' || sub == '晓漫') {
      return true;
    }
    if (subPy.isNotEmpty && protectedPinyins.contains(subPy)) {
      return true;
    }
    return false;
  }

  /// 将文本按字转为前后鼻音归一化的无调拼音数组。
  static List<String> _toPinyinTokens(String text) {
    final result = <String>[];
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      try {
        final py = PinyinHelper.getPinyin(
          ch,
          separator: '',
          format: PinyinFormat.WITHOUT_TONE,
        ).replaceAll(_whitespaceRegExp, '').toLowerCase();
        result.add(_normalizeNasal(py.isEmpty ? ch.toLowerCase() : py));
      } catch (_) {
        result.add(ch.toLowerCase());
      }
    }
    return result;
  }

  static String _normalizeNasal(String py) {
    return py
        .replaceAll('ang', 'an')
        .replaceAll('eng', 'en')
        .replaceAll('ing', 'in')
        .replaceAll('ong', 'on');
  }

  static bool _containsSublist(List<String> haystack, List<String> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    final limit = haystack.length - needle.length;
    for (int i = 0; i <= limit; i++) {
      bool match = true;
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  /// 截取开始词匹配位置之后的剩余文本。
  static String extractRemainingAfterStart(
    String text,
    TriggerMatchResult startMatch,
  ) {
    if (startMatch.endIndex > 0 && startMatch.endIndex < text.length) {
      return text.substring(startMatch.endIndex).trim();
    }
    return text.replaceFirst(startMatch.matchedText, '').trim();
  }
}
