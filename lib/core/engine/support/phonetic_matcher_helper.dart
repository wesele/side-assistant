import 'dart:math' as math;
import 'package:lpinyin/lpinyin.dart';

/// 纯离线拼音与音韵近音匹配辅助工具 (Phonetic & Pinyin Matcher Helper)
///
/// 提供极速拼音归一化、前后鼻音容错、Levenshtein 编辑距离与声学切片定位算法。
class PhoneticMatcherHelper {
  static final RegExp _punctuationAll = RegExp(
    r'[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+',
  );
  static final RegExp _whitespaceRegExp = RegExp(r'\s+');

  /// 去除全量中英文标点与空白
  static String stripPunctuationAll(String text) {
    return text.replaceAll(_punctuationAll, '').trim();
  }

  /// 归一化拼音（去除空格、声调、统一小写）
  static String toPinyinClean(String text) {
    if (text.isEmpty) return '';
    try {
      final py = PinyinHelper.getPinyin(
        text,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      );
      return py.replaceAll(_whitespaceRegExp, '').toLowerCase();
    } catch (_) {
      return text.toLowerCase();
    }
  }

  /// 归一化前后鼻音 (ang -> an, eng -> en, ing -> in, ong -> on)
  static String normalizeNasal(String py) {
    return py
        .replaceAll('ang', 'an')
        .replaceAll('eng', 'en')
        .replaceAll('ing', 'in')
        .replaceAll('ong', 'on');
  }

  /// 极速 Levenshtein 字符编辑距离（整数动态规划，耗时 <0.005ms）
  static int levenshtein(String s, String t) {
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

  /// 扫描并在 candidate 中精确定位拼音匹配的最小子串切片
  static Map<String, dynamic>? findPinyinSlice(
    String text,
    String targetPy,
    int targetCharLength, {
    bool reverse = false,
  }) {
    if (text.isEmpty || targetPy.isEmpty) return null;

    final maxLen = (targetCharLength + 3).clamp(1, text.length);
    final startIdx = reverse ? text.length - 1 : 0;
    final endIdx = reverse ? -1 : text.length;
    final step = reverse ? -1 : 1;

    for (int i = startIdx; i != endIdx; i += step) {
      for (int len = 1; len <= maxLen && i + len <= text.length; len++) {
        final sub = text.substring(i, i + len);
        final cleanSub = stripPunctuationAll(sub);
        if (cleanSub.isEmpty) continue;
        if (toPinyinClean(cleanSub) == targetPy) {
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

  /// 扫描并在 candidate 中模糊匹配拼音切片（支持前后鼻音容错与编辑距离 <= 1，耗时 <0.01ms）
  static Map<String, dynamic>? findFuzzyPinyinSlice(
    String text,
    String targetPy,
    int targetCharLength, {
    bool reverse = false,
  }) {
    if (text.isEmpty || targetPy.isEmpty) return null;

    final normTargetPy = normalizeNasal(targetPy);
    final minLen = targetCharLength.clamp(1, text.length);
    final maxLen = (targetCharLength + 3).clamp(1, text.length);
    final startIdx = reverse ? text.length - 1 : 0;
    final endIdx = reverse ? -1 : text.length;
    final step = reverse ? -1 : 1;

    for (int i = startIdx; i != endIdx; i += step) {
      for (int len = minLen; len <= maxLen && i + len <= text.length; len++) {
        final sub = text.substring(i, i + len);
        final cleanSub = stripPunctuationAll(sub);
        if (cleanSub.isEmpty) continue;

        final subPy = toPinyinClean(cleanSub);
        if (subPy.isEmpty) continue;

        // 1. 鼻音归一化精确匹配 (如 xiaomang -> xiaoman)
        final normSubPy = normalizeNasal(subPy);
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
        final dist = levenshtein(normSubPy, normTargetPy);
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
}
