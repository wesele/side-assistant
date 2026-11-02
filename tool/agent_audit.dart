import 'dart:io';
import 'package:path/path.dart' as p;
import 'agent_check.dart';
import 'build_settings.dart';
import 'build_web_console.dart';

/// SideAssistant AI Coding Agent 友好度体检工具 (Agent Friendliness Audit)
///
/// 核心检查项：
/// 1. 超大文件 (>800行, >1200行)：超过 AI Agent 单次 read_file 上限 (800行)
/// 2. 行尾回车符检查 (CRLF 污染)：易导致 diff 匹配失败与替换崩溃
/// 3. 架构依赖基线合规：Core 层 0 泄漏，Allowlist 维持 0 违规
/// 4. 自动生成物一致性：Web Console 与 AppSettings 门面必须与源文件严格对齐
/// 5. 影子/重复源文件：web_console/ 下不得复活已废弃的 styles.css / app.js
/// 6. git 可信度：lib/ test/ tool/ 下不得有未跟踪源码（否则 git grep / diff 漏检）
/// 7. 测试覆盖：test/ 下新增套件必须能被某个 --scope 跑到
///
/// 用法：
///   dart run tool/agent_audit.dart           # 执行体检报告
///   dart run tool/agent_audit.dart --fix-crlf # 自动将 CRLF 批量转换为 LF
void main(List<String> args) {
  final bool fixCrlf = args.contains('--fix-crlf');
  final projectRoot = Directory.current.path;

  stdout.writeln('======================================================');
  stdout.writeln('🩺 SideAssistant AI Coding Agent 友好度健康体检');
  stdout.writeln('======================================================\n');

  int totalScore = 100;
  final issues = <String>[];

  // 1. 架构基线检查 (Allowlist 违规数)
  stdout.writeln('🔍 [1/7] 架构隔离与基线健康度检查...');
  final allowlistFile = File(p.join(projectRoot, 'tool', 'deps_allowlist.txt'));
  int allowlistCount = 0;
  if (allowlistFile.existsSync()) {
    final lines = allowlistFile
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    allowlistCount = lines.length;
  }
  if (allowlistCount == 0) {
    stdout.writeln('  ✅ 架构允许列表 (Allowlist): 0 违规，Core 与 Service 完全解耦！');
  } else {
    stdout.writeln('  ⚠️ 架构允许列表 (Allowlist): 存在 $allowlistCount 处历史违规');
    totalScore -= (allowlistCount * 5).clamp(0, 30);
    issues.add('架构允许列表存留 $allowlistCount 项遗留反向依赖');
  }

  // 2. 自动生成物同步检查
  stdout.writeln('\n🔍 [2/7] 代码生成物同步检查...');
  final webDartFile = File(p.join(
      projectRoot, 'lib', 'services', 'automation', 'web_console_html.dart'));
  if (webDartFile.existsSync()) {
    try {
      final expectedHtml =
          assembleWebConsoleHtml(baseDir: p.join(projectRoot, 'web_console'));
      final actualDart = webDartFile.readAsStringSync();
      if (!actualDart.contains(expectedHtml)) {
        stdout.writeln(
            '  ❌ Web 控制台生成物与源文件不同步！(需运行: dart run tool/build_web_console.dart)');
        totalScore -= 10;
        issues.add('Web 控制台生成物未同步');
      } else {
        stdout.writeln('  ✅ Web 控制台源文件与生成物保持同步');
      }
    } catch (e) {
      stdout.writeln('  ❌ Web 控制台组装检查异常: $e');
      totalScore -= 10;
    }
  }

  final domainConfigsFile =
      File(p.join(projectRoot, 'lib', 'core', 'models', 'domain_configs.dart'));
  final appSettingsGFile =
      File(p.join(projectRoot, 'lib', 'core', 'models', 'app_settings.g.dart'));
  if (domainConfigsFile.existsSync() && appSettingsGFile.existsSync()) {
    try {
      final expectedG =
          generateAppSettingsCode(domainConfigsFile.readAsStringSync());
      final actualG = appSettingsGFile.readAsStringSync();
      if (expectedG.trim() != actualG.trim()) {
        stdout.writeln(
            '  ❌ AppSettings 领域配置门面与源文件不同步！(需运行: dart run tool/build_settings.dart)');
        totalScore -= 10;
        issues.add('AppSettings 门面未同步');
      } else {
        stdout.writeln('  ✅ AppSettings 领域配置门面与源文件保持同步');
      }
    } catch (e) {
      stdout.writeln('  ❌ AppSettings 门面检查异常: $e');
      totalScore -= 10;
    }
  }

  // 3. 行尾 CRLF 污染检查
  stdout.writeln('\n🔍 [3/7] 跨平台行尾规范检查 (LF vs CRLF)...');
  final scanDirs = ['lib', 'web_console', 'bin', 'tool'];
  final crlfFiles = <String>[];
  final largeFiles = <_LargeFileInfo>[];

  for (final dirName in scanDirs) {
    final dir = Directory(p.join(projectRoot, dirName));
    if (!dir.existsSync()) continue;

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      // 仅检查代码和源文本文件
      if (!{
        '.dart',
        '.js',
        '.css',
        '.html',
        '.sh',
        '.json',
        '.yaml',
        '.txt',
        '.md'
      }.contains(ext)) {
        continue;
      }

      final bytes = entity.readAsBytesSync();
      // 检查 CRLF (0x0D, 0x0A)
      bool hasCrlf = false;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == 13 && bytes[i + 1] == 10) {
          hasCrlf = true;
          break;
        }
      }

      final relPath =
          p.relative(entity.path, from: projectRoot).replaceAll(r'\', '/');

      if (hasCrlf) {
        crlfFiles.add(relPath);
        if (fixCrlf) {
          final content = String.fromCharCodes(bytes);
          final normalized = content.replaceAll('\r\n', '\n');
          entity.writeAsStringSync(normalized, flush: true);
        }
      }

      // 4. 超大文件检查 (跳过自动生成物与构建产物)
      if (relPath.endsWith('.g.dart') ||
          relPath.contains('web_console_html.dart')) {
        continue;
      }

      // 计算行数
      int lineCount = 0;
      for (int i = 0; i < bytes.length; i++) {
        if (bytes[i] == 10) lineCount++;
      }
      if (bytes.isNotEmpty && bytes.last != 10) lineCount++;

      if (lineCount > 800) {
        largeFiles.add(_LargeFileInfo(path: relPath, lines: lineCount));
      }
    }
  }

  if (crlfFiles.isEmpty) {
    stdout.writeln('  ✅ 行尾格式: 全量源码均为统一 LF，无 CRLF 污染！');
  } else {
    if (fixCrlf) {
      stdout.writeln('  🛠️ 已自动修复 ${crlfFiles.length} 个文件中的 CRLF 换行为 LF！');
    } else {
      stdout.writeln(
          '  ⚠️ 发现 ${crlfFiles.length} 个文件包含 CRLF 行尾！(建议运行: dart run tool/agent_audit.dart --fix-crlf)');
      for (final f in crlfFiles.take(5)) {
        stdout.writeln('     - $f');
      }
      if (crlfFiles.length > 5) {
        stdout.writeln('     ... 以及其余 ${crlfFiles.length - 5} 个文件');
      }
      totalScore -= (crlfFiles.length > 10 ? 15 : crlfFiles.length);
      issues.add('${crlfFiles.length} 个文件包含 CRLF 行尾');
    }
  }

  // 4. Agent 读取窗口友好度检查 (>800行)
  stdout.writeln('\n🔍 [4/7] AI Agent 单步阅读窗口友好度检查 (>800行)...');
  if (largeFiles.isEmpty) {
    stdout.writeln('  ✅ 超大文件检查: 0 个超过 800 行的文件！完美适配 AI Agent 工具调用限制。');
  } else {
    largeFiles.sort((a, b) => b.lines.compareTo(a.lines));
    stdout.writeln(
        '  ⚠️ 发现 ${largeFiles.length} 个文件超过 800 行 (Agent read_file 默认窗口上限):');
    for (final f in largeFiles) {
      final tag = f.lines > 1200 ? '🚨 [超大需拆分]' : '⚠️ [注意窗口]';
      stdout.writeln('     $tag ${f.path.padRight(55)} (${f.lines} 行)');
    }
    totalScore -= (largeFiles.length * 3).clamp(0, 25);
    issues.add('${largeFiles.length} 个文件超过 800 行');
  }

  // 5. 影子/重复源文件检查（构建只认 css/ 与 js/ 目录，单体副本会被静默忽略）
  stdout.writeln('\n🔍 [5/7] Web 控制台影子/重复源文件检查...');
  final shadowFiles = <String>[];
  for (final legacy in ['styles.css', 'app.js']) {
    final legacyFile = File(p.join(projectRoot, 'web_console', legacy));
    if (legacyFile.existsSync()) {
      final lines = legacyFile.readAsLinesSync().length;
      shadowFiles.add('web_console/$legacy ($lines 行)');
    }
  }
  if (shadowFiles.isEmpty) {
    stdout.writeln('  ✅ 未发现 web_console 单体影子副本 (styles.css / app.js)');
  } else {
    stdout.writeln('  ❌ 发现 ${shadowFiles.length} 个已废弃的单体影子副本（构建会静默忽略，改动不会生效）:');
    for (final s in shadowFiles) {
      stdout.writeln('     - $s');
    }
    totalScore -= (shadowFiles.length * 8).clamp(0, 16);
    issues.add(
        '删除 web_console 下的影子副本（${shadowFiles.join('、')}），只保留 css/ 与 js/ 模块');
  }

  // 6. git 可信度检查（未跟踪源码会让 git grep / git diff 漏检）
  stdout.writeln('\n🔍 [6/7] git 可信度检查 (未跟踪/未提交源码)...');
  int untrackedSources = 0;
  int modifiedSources = 0;
  final untrackedSamples = <String>[];
  try {
    final gitResult = Process.runSync(
      'git',
      ['status', '--porcelain'],
      workingDirectory: projectRoot,
      runInShell: true,
    );
    if (gitResult.exitCode != 0) {
      stdout.writeln('  ⏭️ 跳过：git status 执行失败（非 git 仓库？）');
    } else {
      const sourceExts = {'.dart', '.js', '.css', '.html'};
      final trackedPrefixes = ['lib/', 'test/', 'tool/'];
      for (final raw in (gitResult.stdout as String).split('\n')) {
        final line = raw.trimRight();
        if (line.length < 4) continue;
        final status = line.substring(0, 2);
        var filePath = line.substring(3).trim();
        if (filePath.contains(' -> ')) {
          filePath = filePath.split(' -> ').last.trim();
        }
        filePath = filePath.replaceAll(r'\', '/').replaceAll('"', '');
        if (!trackedPrefixes.any(filePath.startsWith)) continue;
        if (!sourceExts.contains(p.extension(filePath).toLowerCase())) continue;

        if (status.contains('??')) {
          untrackedSources++;
          if (untrackedSamples.length < 5) untrackedSamples.add(filePath);
        } else if (status.contains('M')) {
          modifiedSources++;
        }
      }

      if (untrackedSources > 0) {
        stdout.writeln(
            '  ❌ 有 $untrackedSources 个源码文件未被 git 跟踪，git grep / git diff 会漏检:');
        for (final s in untrackedSamples) {
          stdout.writeln('     - $s');
        }
        if (untrackedSources > untrackedSamples.length) {
          stdout.writeln(
              '     ... 以及其余 ${untrackedSources - untrackedSamples.length} 个');
        }
        totalScore -= (untrackedSources * 4).clamp(0, 20);
        issues.add(
            '把未跟踪源码纳入 git（git add lib/ test/ tool/），否则 git grep / git diff 会漏检');
      } else if (modifiedSources > 0) {
        stdout.writeln('  ⚠️ 工作区有 $modifiedSources 个未提交改动，git diff 噪声较大');
        totalScore -= 2;
        issues.add('提交或 stash 这 $modifiedSources 个未提交改动，降低 git diff 噪声');
      } else {
        stdout.writeln('  ✅ 工作区干净：lib/ test/ tool/ 下无未跟踪或未提交源码');
      }
    }
  } catch (_) {
    stdout.writeln('  ⏭️ 跳过：无法执行 git（非 git 仓库或未安装 git）');
  }

  // 7. 测试套件 --scope 覆盖检查
  stdout.writeln('\n🔍 [7/7] 测试套件 --scope 覆盖检查...');
  const exemptSuites = {'full_e2e_integration_test.dart', 'widget_test.dart'};
  final coveredSuites = <String>{
    for (final suites in kScopeTestMappings.values) ...suites.map(p.basename),
    ...kFastTestSuites.map(p.basename),
  };
  final uncoveredSuites = <String>[];
  final testDir = Directory(p.join(projectRoot, 'test'));
  if (testDir.existsSync()) {
    for (final entity in testDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
      final name = p.basename(entity.path);
      if (coveredSuites.contains(name) || exemptSuites.contains(name)) continue;
      // live / benchmark / smoke 类需要真实外部服务，显式豁免
      if (name.contains('_live_') ||
          name.endsWith('_live_test.dart') ||
          name.contains('benchmark') ||
          name.contains('smoke')) {
        continue;
      }
      uncoveredSuites.add(name);
    }
  }
  uncoveredSuites.sort();
  if (uncoveredSuites.isEmpty) {
    stdout.writeln('  ✅ 所有测试套件均已被 --scope / 极速模式 / 豁免名单覆盖');
  } else {
    stdout.writeln(
        '  ⚠️ ${uncoveredSuites.length} 个测试套件不在任何 --scope 内，新增测试套件不会被 --scope 跑到:');
    for (final s in uncoveredSuites) {
      stdout.writeln('     - test/$s');
    }
    totalScore -= (uncoveredSuites.length * 2).clamp(0, 6);
    issues.add('把 ${uncoveredSuites.join('、')} 归入 kScopeTestMappings 对应域');
  }

  totalScore = totalScore.clamp(0, 100);

  stdout.writeln('\n======================================================');
  stdout.writeln('📊 体检综合评分: $totalScore / 100 分');
  if (totalScore >= 90) {
    stdout.writeln('🌟 评级: 优秀 (Excellent) - 高度适合 AI Coding Agent 自主编码与迭代');
  } else if (totalScore >= 75) {
    stdout.writeln('🟡 评级: 良好 (Good) - 存在部分超大单体类或格式风险，建议迭代优化');
  } else {
    stdout.writeln('🔴 评级: 需整改 (Needs Attention) - 存在较高阅读截断或 diff 冲突风险');
  }
  stdout.writeln('======================================================\n');

  if (issues.isNotEmpty) {
    stdout.writeln('💡 待优化建议:');
    for (int i = 0; i < issues.length; i++) {
      stdout.writeln('  ${i + 1}. ${issues[i]}');
    }
  }
}

class _LargeFileInfo {
  final String path;
  final int lines;

  _LargeFileInfo({required this.path, required this.lines});
}
