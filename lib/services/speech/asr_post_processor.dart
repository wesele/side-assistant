import 'dart:convert';
import 'dart:io';

import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';

/// 一条同音/领域词替换规则。
class AsrReplacement {
  final String from;
  final String to;

  /// true 表示任何上下文都替换；false 表示只在短句/句首/句尾/待机语境替换，
  /// 避免把正常语句里的同音词误改（例如用户真的在聊“小麦”）。
  final bool always;

  const AsrReplacement(this.from, this.to, {this.always = false});
}

/// ASR 结果后处理器：把领域词、唤醒词、结束词的常见同音误识别统一纠正。
///
/// 设计取舍：
/// - sherpa-onnx 原生的 `hr`（HomophoneReplacer）需要额外生成 `replace.fst`，
///   在 Flutter 端不方便随包分发；这里用纯 Dart 的确定性替换，所有引擎通用。
/// - 只收录“在本应用语境下几乎不可能有第二种含义”的词，默认规则见
///   `assets/models/hr/lexicon.txt`。
class AsrPostProcessor {
  static final AsrPostProcessor instance = AsrPostProcessor._();

  AsrPostProcessor._();

  /// 测试用：构造一个只包含指定规则的实例，不读取资产。
  @visibleForTesting
  factory AsrPostProcessor.forTest(List<AsrReplacement> rules) {
    final processor = AsrPostProcessor._();
    processor._loaded = true;
    processor._replacements
      ..addAll(rules)
      ..sort((a, b) => b.from.length.compareTo(a.from.length));
    return processor;
  }

  bool _loaded = false;
  final List<AsrReplacement> _replacements = <AsrReplacement>[];

  @visibleForTesting
  List<AsrReplacement> get replacements => List.unmodifiable(_replacements);

  /// 内置兜底规则：即使资产文件缺失也能纠正最关键的唤醒/结束词。
  static const List<AsrReplacement> _builtIn = [
    AsrReplacement('小曼', '晓漫'),
    AsrReplacement('小慢', '晓漫'),
    AsrReplacement('晓曼', '晓漫'),
    AsrReplacement('小蛮', '晓漫'),
    AsrReplacement('小满', '晓漫'),
    AsrReplacement('筱漫', '晓漫'),
    AsrReplacement('肖漫', '晓漫'),
    AsrReplacement('小忙', '晓漫'),
    AsrReplacement('回大', '回答', always: true),
    AsrReplacement('会大', '回答', always: true),
    AsrReplacement('会答', '回答', always: true),
    AsrReplacement('回打', '回答', always: true),
    AsrReplacement('回哒', '回答', always: true),
    AsrReplacement('回搭', '回答', always: true),
    AsrReplacement('新启一个', '新起一个', always: true),
  ];

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;

    _replacements.addAll(_builtIn);

    final content = await _readLexicon();
    if (content != null) {
      _parse(content);
    }

    // 去重（同 from 保留第一条），并按 from 长度降序，保证长词优先。
    final seen = <String>{};
    final unique = <AsrReplacement>[];
    for (final r in _replacements) {
      if (r.from.isEmpty || r.from == r.to) continue;
      if (seen.add(r.from)) unique.add(r);
    }
    unique.sort((a, b) => b.from.length.compareTo(a.from.length));
    _replacements
      ..clear()
      ..addAll(unique);
  }

  Future<String?> _readLexicon() async {
    const assetPath = 'assets/models/hr/lexicon.txt';

    // 1. 工程目录（桌面调试）
    final direct = File(assetPath);
    if (direct.existsSync()) {
      try {
        return await direct.readAsString();
      } catch (_) {}
    }

    // 2. 应用文档目录（移动端/服务端）
    try {
      final appDir = await StorageBridge.getAppDocumentsDirectory();
      final local = File('${appDir.path}/$assetPath');
      if (local.existsSync()) {
        return await local.readAsString();
      }
    } catch (_) {}

    // 3. 资产包
    try {
      final bytes = await StorageBridge.loadAssetBytes(assetPath);
      if (bytes != null) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {}
    return null;
  }

  void _parse(String content) {
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      // 支持三种写法：
      //   错误=>正确
      //   错误=>正确=>always
      //   错误<TAB>正确
      String from;
      String to;
      bool always = false;

      if (line.contains('=>')) {
        final parts = line.split('=>').map((e) => e.trim()).toList();
        if (parts.length < 2) continue;
        from = parts[0];
        to = parts[1];
        always = parts.length >= 3 && parts[2].toLowerCase() == 'always';
      } else if (line.contains('\t')) {
        final parts = line.split('\t').map((e) => e.trim()).toList();
        if (parts.length < 2) continue;
        from = parts[0];
        to = parts[1];
      } else {
        continue;
      }

      if (from.isEmpty || to.isEmpty || from == to) continue;
      _replacements.add(AsrReplacement(from, to, always: always));
    }
  }

  /// 对识别结果做同音/领域词纠正。
  ///
  /// [wakeContext] 为 true 时（待机/唤醒阶段）会应用全部规则；
  /// 普通对话中只替换“always”规则（结束词/重置词），以及短句中的唤醒词规则。
  /// 这样既能纠正“回大→回答”，又不会把长句里的“小麦田”误改成“晓漫田”。
  String process(String text, {bool wakeContext = false}) {
    var result = text;
    if (result.isEmpty) return result;

    final isShort = result.length <= 12;

    for (final r in _replacements) {
      if (!result.contains(r.from)) continue;

      if (!r.always && !wakeContext && !isShort) {
        continue;
      }

      result = result.replaceAll(r.from, r.to);
    }

    return result;
  }

  /// 测试用：直接注入规则并跳过资产加载。
  @visibleForTesting
  void loadForTest(List<AsrReplacement> rules) {
    _loaded = true;
    _replacements
      ..clear()
      ..addAll(rules)
      ..sort((a, b) => b.from.length.compareTo(a.from.length));
  }
}
