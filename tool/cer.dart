/// 中文 ASR 的 CER（字符错误率）计算工具。
///
/// 用法：
///   dart run tool/cer.dart "参考文本" "识别文本"
///
/// 也可以作为库被测试/脚本引用。
library;

import 'dart:convert';
import 'dart:io';

/// 归一化：去掉中英文标点、空白，统一小写。
String normalizeForCer(String text) {
  const digits = {
    '0': '零',
    '1': '一',
    '2': '二',
    '3': '三',
    '4': '四',
    '5': '五',
    '6': '六',
    '7': '七',
    '8': '八',
    '9': '九',
  };
  return text
      .replaceAll(
        RegExp(r'[。，、？！；：“”‘’（）《》〈〉【】…—\.,\?!;:()\[\]\s]+'),
        '',
      )
      .replaceAllMapped(RegExp(r'[0-9]'), (m) => digits[m[0]]!)
      .toLowerCase();
}

/// Levenshtein 编辑距离（字符级）。
int levenshteinDistance(String s, String t) {
  if (s == t) return 0;
  if (s.isEmpty) return t.length;
  if (t.isEmpty) return s.length;

  var previous = List<int>.generate(t.length + 1, (i) => i);
  var current = List<int>.filled(t.length + 1, 0);

  for (var i = 0; i < s.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < t.length; j++) {
      final cost = s.codeUnitAt(i) == t.codeUnitAt(j) ? 0 : 1;
      final insertion = current[j] + 1;
      final deletion = previous[j + 1] + 1;
      final substitution = previous[j] + cost;
      current[j + 1] = insertion < deletion
          ? (insertion < substitution ? insertion : substitution)
          : (deletion < substitution ? deletion : substitution);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[t.length];
}

/// 字符错误率：编辑距离 / 参考文本长度。
///
/// 参考文本为空时：识别也为空返回 0，否则返回 1。
double characterErrorRate(String reference, String hypothesis) {
  final r = normalizeForCer(reference);
  final h = normalizeForCer(hypothesis);
  if (r.isEmpty) return h.isEmpty ? 0.0 : 1.0;
  return levenshteinDistance(r, h) / r.length;
}

/// 句子级准确率（完全一致才算对）。
bool isExactMatch(String reference, String hypothesis) {
  return normalizeForCer(reference) == normalizeForCer(hypothesis);
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/cer.dart "参考文本" "识别文本"');
    stderr.writeln('或:  dart run tool/cer.dart --manifest <manifest.json>');
    exitCode = 64;
    return;
  }

  if (args[0] == '--manifest') {
    final file = File(args[1]);
    if (!file.existsSync()) {
      stderr.writeln('manifest 不存在: ${args[1]}');
      exitCode = 66;
      return;
    }
    final data = jsonDecode(file.readAsStringSync()) as List;
    var totalCer = 0.0;
    var exact = 0;
    for (final item in data) {
      final map = item as Map<String, dynamic>;
      final ref = (map['ref'] as String?) ?? '';
      final hyp = (map['hyp'] as String?) ?? '';
      final cer = characterErrorRate(ref, hyp);
      totalCer += cer;
      if (isExactMatch(ref, hyp)) exact++;
      stdout.writeln(
          'CER ${(cer * 100).toStringAsFixed(2)}%  ref="$ref"  hyp="$hyp"');
    }
    if (data.isNotEmpty) {
      stdout.writeln('---');
      stdout.writeln(
          '平均 CER: ${(totalCer / data.length * 100).toStringAsFixed(2)}%');
      stdout
          .writeln('整句准确率: ${(exact / data.length * 100).toStringAsFixed(2)}%');
    }
    return;
  }

  final cer = characterErrorRate(args[0], args[1]);
  stdout.writeln('CER: ${(cer * 100).toStringAsFixed(2)}%');
}
