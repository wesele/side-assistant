import 'dart:io';
import 'package:path/path.dart' as p;
import 'build_settings.dart';
import 'build_web_console.dart';

/// SideAssistant AI Coding Agent 友好度体检工具 (Agent Friendliness Audit)
///
/// 核心检查项：
/// 1. 超大文件 (>800行, >1200行)：超过 AI Agent 单次 read_file 上限 (800行)
/// 2. 行尾回车符检查 (CRLF 污染)：易导致 diff 匹配失败与替换崩溃
/// 3. 架构依赖基线合规：Core 层 0 泄漏，Allowlist 维持 0 违规
/// 4. 自动生成物一致性：Web Console 与 AppSettings 门面必须与源文件严格对齐
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
  stdout.writeln('🔍 [1/4] 架构隔离与基线健康度检查...');
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
  stdout.writeln('\n🔍 [2/4] 代码生成物同步检查...');
  final webDartFile = File(p.join(projectRoot, 'lib', 'services', 'automation', 'web_console_html.dart'));
  if (webDartFile.existsSync()) {
    try {
      final expectedHtml = assembleWebConsoleHtml(baseDir: p.join(projectRoot, 'web_console'));
      final actualDart = webDartFile.readAsStringSync();
      if (!actualDart.contains(expectedHtml)) {
        stdout.writeln('  ❌ Web 控制台生成物与源文件不同步！(需运行: dart run tool/build_web_console.dart)');
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

  final domainConfigsFile = File(p.join(projectRoot, 'lib', 'core', 'models', 'domain_configs.dart'));
  final appSettingsGFile = File(p.join(projectRoot, 'lib', 'core', 'models', 'app_settings.g.dart'));
  if (domainConfigsFile.existsSync() && appSettingsGFile.existsSync()) {
    try {
      final expectedG = generateAppSettingsCode(domainConfigsFile.readAsStringSync());
      final actualG = appSettingsGFile.readAsStringSync();
      if (expectedG.trim() != actualG.trim()) {
        stdout.writeln('  ❌ AppSettings 领域配置门面与源文件不同步！(需运行: dart run tool/build_settings.dart)');
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
  stdout.writeln('\n🔍 [3/4] 跨平台行尾规范检查 (LF vs CRLF)...');
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
      if (!{'.dart', '.js', '.css', '.html', '.sh', '.json', '.yaml', '.txt', '.md'}.contains(ext)) {
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

      final relPath = p.relative(entity.path, from: projectRoot).replaceAll(r'\', '/');

      if (hasCrlf) {
        crlfFiles.add(relPath);
        if (fixCrlf) {
          final content = String.fromCharCodes(bytes);
          final normalized = content.replaceAll('\r\n', '\n');
          entity.writeAsStringSync(normalized, flush: true);
        }
      }

      // 4. 超大文件检查 (跳过自动生成物与构建产物)
      if (relPath.endsWith('.g.dart') || relPath.contains('web_console_html.dart')) {
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
      stdout.writeln('  ⚠️ 发现 ${crlfFiles.length} 个文件包含 CRLF 行尾！(建议运行: dart run tool/agent_audit.dart --fix-crlf)');
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
  stdout.writeln('\n🔍 [4/4] AI Agent 单步阅读窗口友好度检查 (>800行)...');
  if (largeFiles.isEmpty) {
    stdout.writeln('  ✅ 超大文件检查: 0 个超过 800 行的文件！完美适配 AI Agent 工具调用限制。');
  } else {
    largeFiles.sort((a, b) => b.lines.compareTo(a.lines));
    stdout.writeln('  ⚠️ 发现 ${largeFiles.length} 个文件超过 800 行 (Agent read_file 默认窗口上限):');
    for (final f in largeFiles) {
      final tag = f.lines > 1200 ? '🚨 [超大需拆分]' : '⚠️ [注意窗口]';
      stdout.writeln('     $tag ${f.path.padRight(55)} (${f.lines} 行)');
    }
    totalScore -= (largeFiles.length * 3).clamp(0, 25);
    issues.add('${largeFiles.length} 个文件超过 800 行');
  }

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
