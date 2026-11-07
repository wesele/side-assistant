import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 已知的配置契约缺口：key 为 payload key，value 为原因。
///
/// 只允许放“确认不是 bug”或“本轮明确不修”的项，且总数不得超过
/// [_maxKnownGaps]。测试会把这些缺口 print 出来，避免静默通过。
const Map<String, String> _knownGaps = {
  'audioOutputDeviceLabel': 'payload 会提交输出设备的人类可读标签，但回填时标签由 <select> 选中项的文本派生，'
      '不会从 settings.audioOutputDeviceLabel 回读；属于预期设计，不是漏接线。',
};

/// 防“测试变空转”的最低解析数量。低于阈值说明正则已失效，必须更新测试。
const int _minCfgIds = 40;
const int _minPayloadKeys = 40;

/// 本仓库 domain_configs.dart 的 5 个领域类实际有 68 个可持久化字段。
/// 阈值取 60 是为了拦住正则失效，同时不把字段数量当成业务契约写死。
const int _minDomainFields = 60;
const int _minPopulatedProps = 40;
const int _maxKnownGaps = 5;

void main() {
  final repoRoot = Directory.current.path;
  final bodyHtml = _readText(repoRoot, 'web_console/body.html');
  final settingsJs = _readText(repoRoot, 'web_console/js/08_settings.js');
  final domainSource = _readText(
    repoRoot,
    'lib/core/models/domain_configs.dart',
  );

  final domIds = _extractDomCfgIds(bodyHtml);
  final jsRefs = _extractJsCfgRefs(settingsJs);
  final payloadKeys = _extractPayloadKeys(settingsJs);
  final domainFields = _extractDomainFields(domainSource);
  final populatedProps = _extractPopulatedProps(settingsJs);

  group('Web 控制台配置字段契约', () {
    setUpAll(() {
      // ignore: avoid_print
      print(
        '配置契约解析结果: DOM cfg id=${domIds.length}, '
        'JS cfg 引用=${jsRefs.length}, payload keys=${payloadKeys.length}, '
        'domain 字段=${domainFields.length}, 可回填属性=${populatedProps.length}',
      );
      _guardCount('DOM cfg id', domIds.length, _minCfgIds);
      _guardCount('payload key', payloadKeys.length, _minPayloadKeys);
      _guardCount('domain 字段', domainFields.length, _minDomainFields);
      _guardCount('可回填属性', populatedProps.length, _minPopulatedProps);
      expect(
        _knownGaps.length,
        lessThanOrEqualTo(_maxKnownGaps),
        reason: '已知缺口超过 $_maxKnownGaps 条，问题比预期严重；请先修复接线，而不是继续扩充例外清单。',
      );
    });

    test('断言 1: body.html 的 cfg_* id 与 08_settings.js 引用双向一致', () {
      final deadInputs = domIds.difference(jsRefs).toList()..sort();
      final danglingRefs = jsRefs.difference(domIds).toList()..sort();

      expect(
        deadInputs,
        isEmpty,
        reason:
            '以下输入框在 body.html 中存在，但 08_settings.js 从未引用（渲染了但没人读）: $deadInputs',
      );
      expect(
        danglingRefs,
        isEmpty,
        reason: '以下 cfg_* 在 08_settings.js 中被引用，但 body.html 没有对应 id'
            '（getElementById 返回 null，运行时才炸）: $danglingRefs',
      );
    });

    test('断言 2: payload key 必须是 domain_configs.dart 中真实存在的配置字段', () {
      final unknown = payloadKeys.difference(domainFields).toList()..sort();

      expect(
        unknown,
        isEmpty,
        reason: '以下 payload key 不是真实配置字段（字段重命名后忘了改 JS，'
            '后端会静默忽略，用户改了不会保存）: $unknown',
      );
    });

    test('断言 3: payload 的每个 key 都要能被回填', () {
      final missing = payloadKeys.difference(populatedProps).toList()..sort();
      final unexpected =
          missing.where((key) => !_knownGaps.containsKey(key)).toList();

      if (_knownGaps.isNotEmpty) {
        // ignore: avoid_print
        print('已知配置契约缺口 (${_knownGaps.length}):');
        for (final entry in _knownGaps.entries) {
          // ignore: avoid_print
          print('  - ${entry.key}: ${entry.value}');
        }
      }

      expect(
        unexpected,
        isEmpty,
        reason: '以下 payload key 能保存但回填时从不读取（刷新页面后 UI 显示旧值）: $unexpected',
      );

      final staleGaps = _knownGaps.keys
          .where((key) => !missing.contains(key))
          .toList()
        ..sort();
      expect(
        staleGaps,
        isEmpty,
        reason: '例外清单中的字段已不再是缺口（或已不在 payload 中），请清理: $staleGaps',
      );
    });
  });
}

String _readText(String root, String relativePath) {
  final file = File('$root/$relativePath');
  if (!file.existsSync()) {
    fail('找不到文件: ${file.path}（测试需在仓库根目录运行）');
  }
  return file.readAsStringSync();
}

Set<String> _extractDomCfgIds(String html) {
  final regex = RegExp(r'''id\s*=\s*["'](cfg_[A-Za-z0-9_]+)["']''');
  return regex.allMatches(html).map((m) => m.group(1)!).toSet();
}

Set<String> _extractJsCfgRefs(String js) {
  return RegExp(r'\bcfg_[A-Za-z0-9_]+')
      .allMatches(js)
      .map((m) => m.group(0)!)
      .toSet();
}

Set<String> _extractPayloadKeys(String js) {
  final literal = _extractObjectLiteral(js, 'const payload = ');
  final regex = RegExp(
    r'^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:',
    multiLine: true,
  );
  return regex.allMatches(literal).map((m) => m.group(1)!).toSet();
}

Set<String> _extractDomainFields(String source) {
  final fields = <String>{};

  // 领域字段统一声明在类体顶层（两空格缩进），排除方法内的局部 final 变量。
  final fieldRegex = RegExp(
    r'^  final\s+.+?\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*;',
    multiLine: true,
  );
  for (final match in fieldRegex.allMatches(source)) {
    fields.add(match.group(1)!);
  }

  // toMap() 的 key 也是可持久化配置字段（含 enableStartWordDetection 这类计算字段）。
  final toMapBlocks = RegExp(
    r'Map<String, dynamic> toMap\(\)\s*\{\s*return\s*\{(.*?)\};',
    dotAll: true,
  ).allMatches(source).toList();
  if (toMapBlocks.length < 5) {
    fail(
      'domain_configs.dart 只解析到 ${toMapBlocks.length} 个 toMap() 块（要求 >= 5），'
      '解析规则可能已失效，请更新本测试的正则',
    );
  }
  final mapKeyRegex = RegExp(
    r"^\s*'([A-Za-z_$][A-Za-z0-9_$]*)':",
    multiLine: true,
  );
  for (final block in toMapBlocks) {
    for (final match in mapKeyRegex.allMatches(block.group(1)!)) {
      fields.add(match.group(1)!);
    }
  }

  return fields;
}

Set<String> _extractPopulatedProps(String js) {
  final props = <String>{};
  final populateBody = _extractFunctionBody(
    js,
    'function populateSettingsForm(s)',
  );

  // textIds / boolIds / intIds 通过 s[id] 动态回填，数组里的 id 就是读取的属性名。
  for (final listName in ['textIds', 'boolIds', 'intIds']) {
    final block = RegExp(
      'const $listName = \\[(.*?)\\];',
      dotAll: true,
    ).firstMatch(populateBody);
    if (block == null) {
      fail('populateSettingsForm 中未找到 $listName 数组，解析规则可能已失效');
    }
    for (final match in RegExp(
      r"'([A-Za-z_$][A-Za-z0-9_$]*)'",
    ).allMatches(block.group(1)!)) {
      props.add(match.group(1)!);
    }
  }

  // sliders 的每项形如 ['vadThreshold', formatter]。
  final sliderBlock = RegExp(
    r'const sliders = \[(.*?)\];',
    dotAll: true,
  ).firstMatch(populateBody);
  if (sliderBlock == null) {
    fail('populateSettingsForm 中未找到 sliders 数组，解析规则可能已失效');
  }
  for (final match in RegExp(
    r"\[\s*'([A-Za-z_$][A-Za-z0-9_$]*)'",
  ).allMatches(sliderBlock.group(1)!)) {
    props.add(match.group(1)!);
  }

  // 显式属性读取：s.xxx / s['xxx']。
  for (final match in RegExp(
    r'\bs\.([A-Za-z_$][A-Za-z0-9_$]*)',
  ).allMatches(populateBody)) {
    props.add(match.group(1)!);
  }
  for (final match in RegExp(
    r"\bs\[\s*'([A-Za-z_$][A-Za-z0-9_$]*)'\s*\]",
  ).allMatches(populateBody)) {
    props.add(match.group(1)!);
  }

  // 硬件下拉框由 populateHardwareSelects 从 currentSettings 回填。
  final hardwareBody = _extractFunctionBody(
    js,
    'function populateHardwareSelects()',
  );
  for (final match in RegExp(
    r'\bcurrentSettings\.([A-Za-z_$][A-Za-z0-9_$]*)',
  ).allMatches(hardwareBody)) {
    props.add(match.group(1)!);
  }

  return props;
}

/// 从 [marker] 之后找到第一个 `{`，按花括号配对返回完整对象字面量。
///
/// 仅用于本测试覆盖的简单 JS 字面量/函数体，内部字符串不含花括号。
String _extractObjectLiteral(String source, String marker) {
  final markerIndex = source.indexOf(marker);
  if (markerIndex < 0) {
    fail('未找到 "$marker"，解析规则可能已失效');
  }
  final start = source.indexOf('{', markerIndex);
  if (start < 0) {
    fail('"$marker" 之后没有对象字面量');
  }
  var depth = 0;
  for (var i = start; i < source.length; i++) {
    final ch = source.codeUnitAt(i);
    if (ch == 0x7B) {
      depth++;
    } else if (ch == 0x7D) {
      depth--;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  fail('"$marker" 的对象字面量没有闭合');
}

String _extractFunctionBody(String source, String signature) {
  final signatureIndex = source.indexOf(signature);
  if (signatureIndex < 0) {
    fail('未找到函数 "$signature"，解析规则可能已失效');
  }
  final start = source.indexOf('{', signatureIndex);
  if (start < 0) {
    fail('函数 "$signature" 没有函数体');
  }
  var depth = 0;
  for (var i = start; i < source.length; i++) {
    final ch = source.codeUnitAt(i);
    if (ch == 0x7B) {
      depth++;
    } else if (ch == 0x7D) {
      depth--;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  fail('函数 "$signature" 的函数体没有闭合');
}

void _guardCount(String label, int actual, int minimum) {
  expect(
    actual,
    greaterThanOrEqualTo(minimum),
    reason: '$label 只解析到 $actual 项（要求 >= $minimum）。'
        '解析规则可能已失效，请更新本测试的正则，而不是让它静默通过。',
  );
}
