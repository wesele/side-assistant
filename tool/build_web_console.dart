import 'dart:io';

import 'build_settings.dart';

/// 从 web_console/ 组装并同步生成 lib/services/automation/web_console_html.dart
///
/// 唯一事实来源（勿新增单体副本）:
///   - web_console/index.html   模板骨架（仅含三个插槽标记）
///   - web_console/body.html    页面 DOM 结构
///   - web_console/css/*.css    样式模块（按文件名排序拼接）
///   - web_console/js/*.js      脚本模块（按文件名排序拼接）
///
/// 用法:
///   dart run tool/build_web_console.dart   # 组装并生成 web_console_html.dart

const String kStylesPlaceholder = '/* {{STYLES}} */';
const String kBodyPlaceholder = '<!-- {{BODY}} -->';
const String kAppPlaceholder = '// {{APP}}';

/// 组装 Web 控制台完整 HTML 字符串
String assembleWebConsoleHtml({String baseDir = 'web_console'}) {
  final indexFile = File('$baseDir/index.html');
  final stylesFile = File('$baseDir/styles.css');
  final bodyFile = File('$baseDir/body.html');
  final appFile = File('$baseDir/app.js');

  if (!indexFile.existsSync()) {
    throw StateError('未找到 $baseDir/index.html');
  }

  final template = indexFile.readAsStringSync();

  // 若尚未拆解，仍是包含完整内容的单体 index.html（向下兼容）
  if (!stylesFile.existsSync() &&
      !bodyFile.existsSync() &&
      !appFile.existsSync() &&
      !Directory('$baseDir/css').existsSync() &&
      !Directory('$baseDir/js').existsSync()) {
    return template.trim();
  }

  // 1. 读取 Styles (优先 web_console/css/*.css，否则 styles.css)
  String styles = '';
  final cssDir = Directory('$baseDir/css');
  if (cssDir.existsSync()) {
    final cssFiles = cssDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.css'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (cssFiles.isNotEmpty) {
      styles = cssFiles.map((f) => f.readAsStringSync().trim()).join('\n\n');
    }
  }
  if (styles.isEmpty && stylesFile.existsSync()) {
    styles = stylesFile.readAsStringSync().trim();
  }

  // 2. 读取 Body
  final body = bodyFile.existsSync() ? bodyFile.readAsStringSync().trim() : '';

  // 3. 读取 App JS (优先 web_console/js/*.js，否则 app.js)
  String app = '';
  final jsDir = Directory('$baseDir/js');
  if (jsDir.existsSync()) {
    final jsFiles = jsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.js'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (jsFiles.isNotEmpty) {
      app = jsFiles.map((f) => f.readAsStringSync().trim()).join('\n\n');
    }
  }
  if (app.isEmpty && appFile.existsSync()) {
    app = appFile.readAsStringSync().trim();
  }

  String html = template;
  if (html.contains(kStylesPlaceholder)) {
    html = html.replaceFirst(kStylesPlaceholder, styles);
  } else if (html.contains('{{STYLES}}')) {
    html = html.replaceFirst('{{STYLES}}', styles);
  }

  if (html.contains(kBodyPlaceholder)) {
    html = html.replaceFirst(kBodyPlaceholder, body);
  } else if (html.contains('{{BODY}}')) {
    html = html.replaceFirst('{{BODY}}', body);
  }

  if (html.contains(kAppPlaceholder)) {
    html = html.replaceFirst(kAppPlaceholder, app);
  } else if (html.contains('{{APP}}')) {
    html = html.replaceFirst('{{APP}}', app);
  }

  return html.trim();
}

void main(List<String> args) {
  final html = assembleWebConsoleHtml();

  final dartFile = File('lib/services/automation/web_console_html.dart');
  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln(
      '// Source: web_console/ (index.html, body.html, css/*.css, js/*.js)');
  buffer.writeln('// To rebuild: dart run tool/build_web_console.dart');
  buffer.writeln();
  buffer.writeln('/// Linux 服务器版 Web 管理与对话控制台（单文件自包含 HTML/CSS/JS，零外部 CDN 依赖）');
  buffer.writeln(
      '/// 界面视觉与交互全面对齐 Windows / Android 客户端 (AppTheme / HomeScreen / ChatHistoryDrawer / SettingsScreen)');
  buffer.writeln('String buildWebConsoleHtml() => _kWebConsoleHtml;');
  buffer.writeln();
  buffer.writeln("const String _kWebConsoleHtml = r'''$html''';");

  dartFile.writeAsStringSync(formatDartSource(buffer.toString()));
  // ignore: avoid_print
  print('Successfully generated ${dartFile.path} (${html.length} bytes)');
}
