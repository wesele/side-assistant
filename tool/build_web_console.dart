import 'dart:io';

/// 从 web_console/index.html 自动构建/同步生成 lib/services/automation/web_console_html.dart
///
/// 用法:
///   dart run tool/build_web_console.dart
void main() {
  final htmlFile = File('web_console/index.html');
  if (!htmlFile.existsSync()) {
    stderr.writeln('未找到 web_console/index.html');
    exit(1);
  }

  final html = htmlFile.readAsStringSync().trim();

  final dartFile = File('lib/services/automation/web_console_html.dart');
  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln('// Source: web_console/index.html');
  buffer.writeln('// To rebuild: dart run tool/build_web_console.dart');
  buffer.writeln();
  buffer.writeln('/// Linux 服务器版 Web 管理与对话控制台（单文件自包含 HTML/CSS/JS，零外部 CDN 依赖）');
  buffer.writeln('/// 界面视觉与交互全面对齐 Windows / Android 客户端 (AppTheme / HomeScreen / ChatHistoryDrawer / SettingsScreen)');
  buffer.writeln('String buildWebConsoleHtml() => _kWebConsoleHtml;');
  buffer.writeln();
  buffer.writeln("const String _kWebConsoleHtml = r'''$html''';");

  dartFile.writeAsStringSync(buffer.toString());
  // ignore: avoid_print
  print('Successfully generated ${dartFile.path} (${html.length} bytes)');
}
