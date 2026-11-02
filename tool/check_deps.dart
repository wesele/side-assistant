import 'dart:io';
import 'package:path/path.dart' as p;
import 'build_settings.dart';
import 'build_web_console.dart';

/// 架构依赖约束与循环依赖自动化合规检查工具 (Architecture & Dependency Guard)
///
/// 检查规则：
/// 1. 文件级循环依赖（Tarjan SCC 算法）：严格 0 环路；
/// 2. 分层架构依赖合规：
///    - core/** 不得依赖 services/**, ui/**, controllers/**
///    - ui/** 不得直接依赖 services/**（需经 controller / port 间接访问）
///    - 纯 Dart 核心层（core/**, services/**）不得泄漏 package:flutter 依赖（core/platform/*_flutter.dart 除外）
/// 3. 白名单管控：
///    - 历史存量违规记录于 tool/deps_allowlist.txt
///    - 任何未在白名单中的新增违规将直接阻断 CI（Exit code 1）
///    - 运行 `dart run tool/check_deps.dart --update-allowlist` 可更新白名单基线
void main(List<String> args) {
  final bool updateAllowlist = args.contains('--update-allowlist');
  final projectRoot = Directory.current.path;
  final libDir = p.join(projectRoot, 'lib');
  final binDir = p.join(projectRoot, 'bin');

  // 0. Web 控制台源文件与生成物同步检查
  final webDartFile = File(p.join(projectRoot, 'lib', 'services', 'automation', 'web_console_html.dart'));
  if (webDartFile.existsSync()) {
    try {
      final expectedHtml = assembleWebConsoleHtml(baseDir: p.join(projectRoot, 'web_console'));
      final actualDart = webDartFile.readAsStringSync();
      if (!actualDart.contains(expectedHtml)) {
        stderr.writeln('\n❌ Web 控制台源文件与生成物不同步！');
        stderr.writeln('  web_console/ 源文件 (index.html, body.html, css/*.css, js/*.js) 已被修改，但生成物 lib/services/automation/web_console_html.dart 未更新。');
        stderr.writeln('  请立即运行构建: dart run tool/build_web_console.dart\n');
        exit(1);
      }
    } catch (e) {
      stderr.writeln('\n❌ Web 控制台组装校验异常: $e');
      exit(1);
    }
  }

  // 0.1 领域配置源文件与 AppSettings 门面生成物同步检查
  final domainConfigsFile = File(p.join(projectRoot, 'lib', 'core', 'models', 'domain_configs.dart'));
  final appSettingsGFile = File(p.join(projectRoot, 'lib', 'core', 'models', 'app_settings.g.dart'));
  if (domainConfigsFile.existsSync() && appSettingsGFile.existsSync()) {
    final expectedG = generateAppSettingsCode(domainConfigsFile.readAsStringSync());
    final actualG = appSettingsGFile.readAsStringSync();
    if (expectedG.trim() != actualG.trim()) {
      stderr.writeln('\n❌ 领域配置源文件与 AppSettings 门面生成物不同步！');
      stderr.writeln('  lib/core/models/domain_configs.dart 已被修改，但生成物 lib/core/models/app_settings.g.dart 未更新。');
      stderr.writeln('  请立即运行构建: dart run tool/build_settings.dart\n');
      exit(1);
    }
  }

  final files = <String>[];
  void collectDartFiles(Directory dir) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        files.add(p.normalize(entity.path));
      }
    }
  }

  collectDartFiles(Directory(libDir));
  collectDartFiles(Directory(binDir));

  final importRegex = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
  final graph = <String, Set<String>>{};
  final flutterImports = <String, Set<String>>{};

  String toRel(String path) => p.relative(path, from: projectRoot).replaceAll(r'\', '/');

  for (final file in files) {
    final relFile = toRel(file);
    graph[relFile] = <String>{};
    final content = File(file).readAsStringSync();

    for (final match in importRegex.allMatches(content)) {
      final uri = match.group(1)!;

      if (uri.startsWith('package:flutter')) {
        flutterImports.putIfAbsent(relFile, () => <String>{}).add(uri);
        continue;
      }
      if (uri.startsWith('dart:')) continue;

      String? targetPath;
      if (uri.startsWith('package:side_assistant/')) {
        final rel = uri.substring('package:side_assistant/'.length);
        targetPath = p.normalize(p.join(libDir, rel));
      } else if (!uri.startsWith('package:')) {
        targetPath = p.normalize(p.join(p.dirname(file), uri));
      }

      if (targetPath != null && File(targetPath).existsSync()) {
        graph[relFile]!.add(toRel(targetPath));
      }
    }
  }

  // ---- 1. 循环依赖检查 (Tarjan SCC) ----
  int index = 0;
  final indices = <String, int>{};
  final lowlink = <String, int>{};
  final onStack = <String, bool>{};
  final stack = <String>[];
  final sccs = <List<String>>[];

  void strongConnect(String v) {
    indices[v] = index;
    lowlink[v] = index;
    index++;
    stack.add(v);
    onStack[v] = true;

    for (final w in graph[v] ?? <String>{}) {
      if (!indices.containsKey(w)) {
        strongConnect(w);
        if (lowlink[w]! < lowlink[v]!) {
          lowlink[v] = lowlink[w]!;
        }
      } else if (onStack[w] == true) {
        if (indices[w]! < lowlink[v]!) {
          lowlink[v] = indices[w]!;
        }
      }
    }

    if (lowlink[v] == indices[v]) {
      final scc = <String>[];
      while (true) {
        final w = stack.removeLast();
        onStack[w] = false;
        scc.add(w);
        if (w == v) break;
      }
      if (scc.length > 1 || (scc.length == 1 && graph[v]?.contains(v) == true)) {
        sccs.add(scc);
      }
    }
  }

  for (final node in graph.keys) {
    if (!indices.containsKey(node)) {
      strongConnect(node);
    }
  }

  if (sccs.isNotEmpty) {
    stderr.writeln('❌ 严重错误: 检测到 ${sccs.length} 个循环依赖！');
    for (int i = 0; i < sccs.length; i++) {
      stderr.writeln('\nCycle #${i + 1} (${sccs[i].length} files):');
      for (final f in sccs[i]) {
        stderr.writeln('  - $f');
      }
    }
    exit(1);
  }

  stdout.writeln('✅ 循环依赖检查通过：全量 ${files.length} 个 Dart 文件中 0 环路。');

  // ---- 2. 分层架构约束检查 ----
  final currentViolations = <String>{};

  for (final source in graph.keys) {
    for (final target in graph[source]!) {
      // 规则 A: core/** 不得依赖 services/**, ui/**, controllers/**
      // 注：lib/core/di/app_container.dart 为 Composition Root（装配根），
      // 负责将抽象 Ports 绑定到具体 Services 实现，豁免 CORE_DEPENDS_ON_SERVICE 检查。
      if (source.startsWith('lib/core/')) {
        if (target.startsWith('lib/services/')) {
          if (source == 'lib/core/di/app_container.dart') {
            continue;
          }
          currentViolations.add('CORE_DEPENDS_ON_SERVICE:$source -> $target');
        } else if (target.startsWith('lib/ui/')) {
          currentViolations.add('CORE_DEPENDS_ON_UI:$source -> $target');
        } else if (target.startsWith('lib/controllers/')) {
          currentViolations.add('CORE_DEPENDS_ON_CONTROLLER:$source -> $target');
        }
      }

      // 规则 B: ui/** 不得直接依赖 services/**
      if (source.startsWith('lib/ui/') && target.startsWith('lib/services/')) {
        currentViolations.add('UI_DEPENDS_ON_SERVICE:$source -> $target');
      }
    }
  }

  // 规则 C: 检查 flutter 依赖泄漏
  for (final source in flutterImports.keys) {
    if (source.startsWith('lib/ui/') ||
        source == 'lib/main.dart' ||
        source.endsWith('_flutter.dart')) {
      continue;
    }
    for (final uri in flutterImports[source]!) {
      currentViolations.add('FLUTTER_LEAK:$source -> $uri');
    }
  }

  // ---- 3. 白名单对比与裁决 ----
  final allowlistFile = File(p.join(projectRoot, 'tool', 'deps_allowlist.txt'));
  final sortedViolations = currentViolations.toList()..sort();

  if (updateAllowlist) {
    allowlistFile.writeAsStringSync(
      '# SideAssistant 存量架构分层违规白名单 (仅限存量，逐期治理缩减，严禁新增)\n'
      '# Generated by tool/check_deps.dart --update-allowlist\n'
      '# Total items: ${sortedViolations.length}\n\n'
      '${sortedViolations.join('\n')}\n',
    );
    stdout.writeln('📝 已更新白名单基线: ${allowlistFile.path} (共 ${sortedViolations.length} 项违规)');
    exit(0);
  }

  final Set<String> allowlist = allowlistFile.existsSync()
      ? allowlistFile
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toSet()
      : <String>{};

  final newViolations = currentViolations.difference(allowlist).toList()..sort();
  final resolvedViolations = allowlist.difference(currentViolations).toList()..sort();

  stdout.writeln('\n架构依赖合规评估:');
  stdout.writeln('  - 当前存量白名单项: ${allowlist.length}');
  stdout.writeln('  - 当前实测违规总数: ${currentViolations.length}');
  stdout.writeln('  - 已经消除的违规数: ${resolvedViolations.length}');
  stdout.writeln('  - 未经授权的新违规: ${newViolations.length}');

  if (resolvedViolations.isNotEmpty) {
    stdout.writeln('\n🎉 恭喜！本次检查发现 ${resolvedViolations.length} 个历史违规已被成功消除！');
    for (final r in resolvedViolations.take(10)) {
      stdout.writeln('  - [RESOLVED] $r');
    }
    if (resolvedViolations.length > 10) {
      stdout.writeln('  ... 以及其余 ${resolvedViolations.length - 10} 项。请运行 `dart run tool/check_deps.dart --update-allowlist` 固化成果。');
    }
  }

  if (newViolations.isNotEmpty) {
    stderr.writeln('\n❌ 架构合规门禁未通过！发现 ${newViolations.length} 个新增分层/依赖泄漏违规：');
    for (final nv in newViolations) {
      stderr.writeln('  - [NEW VIOLATION] $nv');
    }
    stderr.writeln('\n请遵循六边形架构设计，通过 Port 接口抽象或将平台逻辑下沉至 core/platform 解决违规。');
    exit(1);
  }

  stdout.writeln('\n✅ 架构合规门禁检查通过 (无新增违规)。');
}
