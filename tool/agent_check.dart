import 'dart:io';

import 'build_settings.dart';
import 'build_web_console.dart';

/// AI Coding Agent 与开发者一键自检验收中枢 (Agent & Dev Quick Verification Suite)
///
/// 功能：
/// 1. 自动检测并同步构建 Web 控制台 (web_console/index.html -> web_console_html.dart)
/// 2. 架构守卫与循环依赖检查 (tool/check_deps.dart)
/// 3. Dart 静态代码分析 (dart analyze --fatal-infos)
/// 4. 纯 Dart 边缘服务器编译健康检查 (dart compile kernel bin/linux_server.dart)
/// 5. 核心微端口与契约快速测试，或指定领域靶向单测，或全量测试
///
/// 用法:
///   dart run tool/agent_check.dart                                 # 极速验证 (~5-10秒)
///   dart run tool/agent_check.dart --audit                         # AI Agent 友好度体检与评估报告
///   dart run tool/agent_check.dart --scope <speech|dialogue|vision|server|config> # 靶向领域单测
///   dart run tool/agent_check.dart --full                          # 全量验收 (全量 500+ 测试)
/// --scope 域到测试套件的映射（单一事实来源，tool/agent_audit.dart 复用同一份）
const Map<String, List<String>> kScopeTestMappings = {
  'speech': [
    'test/voice_pipeline_coordinator_test.dart',
    'test/voice_listening_live_test.dart',
    'test/asr_settings_test.dart',
    'test/asr_engine_selection_test.dart',
    'test/asr_engine_factory_test.dart',
    'test/vad_verification_test.dart',
    'test/echo_rejection_test.dart',
    'test/tts_barge_in_echo_test.dart',
    'test/edge_tts_service_test.dart',
    'test/speaker_verification_test.dart',
    'test/target_speaker_extraction_test.dart',
    'test/audio_ring_test.dart',
    'test/acknowledge_beep_test.dart',
    'test/end_word_compat_test.dart',
    'test/end_word_tail_constraint_test.dart',
    'test/streaming_zipformer_verification_test.dart',
    'test/final_transcript_test.dart',
    'test/mfcc_dtw_test.dart',
    'test/multi_trigger_words_test.dart',
    'test/cer_test.dart',
    'test/assistant_engine_speech_stress_test.dart',
    'test/coordinators_stress_test.dart',
  ],
  'dialogue': [
    'test/dialogue_intent_coordinator_test.dart',
    'test/dialogue_decomposed_components_test.dart',
    'test/dialogue_subcomponents_adversarial_test.dart',
    'test/session_coordinator_test.dart',
    'test/assistant_engine_test.dart',
    'test/assistant_logic_test.dart',
    'test/llm_intent_dialogue_test.dart',
    'test/llm_thinking_and_clean_reply_test.dart',
    'test/llm_tool_contract_registry_test.dart',
    'test/llm_tool_adversarial_stress_test.dart',
    'test/llm_tool_registry_adversarial_barrage_test.dart',
    'test/streaming_json_reply_parser_test.dart',
    'test/continuous_dialog_mode_test.dart',
    'test/chat_history_test.dart',
    'test/send_text_message_test.dart',
    'test/gemini_language_filter_test.dart',
    'test/web_search_tool_test.dart',
    'test/lightrag_service_test.dart',
    'test/adversarial_challenge_m6_1_test.dart',
    'test/assistant_engine_concurrency_stress_test.dart',
  ],
  'vision': [
    'test/vision_intent_and_camera_test.dart',
    'test/camera_capture_source_spi_test.dart',
    'test/camera_service_stress_test.dart',
    'test/nano_camera_source_test.dart',
  ],
  'server': [
    'test/server_transport_modular_test.dart',
    'test/http_server_transport_adversarial_test.dart',
    'test/linux_server_web_console_test.dart',
    'test/linux_hal_modular_test.dart',
    'test/linux_hal_adversarial_test.dart',
    'test/driver_port_adversarial_test.dart',
  ],
  'config': [
    'test/config_domain_serialization_test.dart',
    'test/incremental_settings_update_test.dart',
    'test/service_locator_di_test.dart',
    'test/llm_model_dropdown_test.dart',
    'test/app_container_stress_test.dart',
  ],
};

/// 默认极速模式覆盖的测试套件（有意取舍，勿静默扩大）
const List<String> kFastTestSuites = [
  'test/coordinator_ports_contract_test.dart',
  'test/server_transport_modular_test.dart',
];

/// 会劫持 flutter_tester localhost WebSocket 的代理环境变量（大小写不敏感匹配）
const Set<String> kProxyEnvKeys = {'http_proxy', 'https_proxy'};

void main(List<String> args) async {
  if (args.contains('--audit')) {
    final auditProcess = await Process.start(
      'dart',
      ['run', 'tool/agent_audit.dart', ...args.where((a) => a == '--fix-crlf')],
      mode: ProcessStartMode.inheritStdio,
    );
    exit(await auditProcess.exitCode);
  }

  final bool isFull = args.contains('--full');

  // 解析 --scope 选项
  String? scope;
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--scope' && i + 1 < args.length) {
      scope = args[i + 1].toLowerCase();
      break;
    } else if (arg.startsWith('--scope=')) {
      scope = arg.substring('--scope='.length).toLowerCase();
      break;
    }
  }

  if (scope != null && !kScopeTestMappings.containsKey(scope)) {
    stderr.writeln('❌ 无效的 --scope 参数: "$scope"');
    stderr.writeln('可选的合法作用域: ${kScopeTestMappings.keys.join(', ')}');
    exit(1);
  }

  final stopwatch = Stopwatch()..start();

  final String modeLabel;
  if (isFull) {
    modeLabel = '全量验收 (--full)';
  } else if (scope != null) {
    modeLabel = '靶向领域测试 (--scope $scope)';
  } else {
    modeLabel = '极速验证 (Core Verification)';
  }

  stdout.writeln('======================================================');
  stdout.writeln('🤖 SideAssistant AI Agent 一键自检中枢 (Agent Check)');
  stdout.writeln('模式: $modeLabel');
  if (_proxyEnvDetected()) {
    stdout.writeln('ℹ️ 已为测试子进程剥离 HTTP_PROXY（本机代理会打断 flutter_tester 的 localhost WebSocket）');
  }
  stdout.writeln('======================================================\n');

  // 0. 自动检测并同步构建 Web 控制台与领域配置门面
  await _autoSyncWebConsole();
  await _autoSyncAppSettings();

  final results = <_CheckItem>[];

  // 1. 架构分层守卫与 Web Console 同步校验
  await _runStep(
    name: '架构分层与依赖守卫 (tool/check_deps.dart)',
    command: 'dart',
    args: ['run', 'tool/check_deps.dart'],
    results: results,
  );

  // 2. 静态代码分析
  await _runStep(
    name: '静态代码分析 (dart analyze --fatal-infos)',
    command: 'dart',
    args: ['analyze', '--fatal-infos'],
    results: results,
  );

  // 3. 纯 Dart 边缘服务器构建检查 (确保未泄漏 flutter/dart:ui 依赖)
  const tempDill = 'build/agent_check_temp.dill';
  await _runStep(
    name: 'Linux 边缘服务器纯 Dart 编译检查',
    command: 'dart',
    args: ['compile', 'kernel', 'bin/linux_server.dart', '-o', tempDill],
    results: results,
    onSuccess: () {
      final f = File(tempDill);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    },
  );

  // 4. 契约与单元测试
  final List<String> testArgs;
  final String testStepName;
  if (isFull) {
    testArgs = ['test'];
    testStepName = '全量单元与压力测试 (flutter test)';
  } else if (scope != null) {
    testArgs = ['test', ...kScopeTestMappings[scope]!];
    testStepName = '靶向领域单测 [$scope] (${kScopeTestMappings[scope]!.length} 个测试套件)';
  } else {
    testArgs = ['test', ...kFastTestSuites];
    testStepName = '核心微端口与契约快速测试';
  }

  await _runStep(
    name: testStepName,
    command: 'flutter',
    args: testArgs,
    results: results,
    // flutter_tester 的 localhost WebSocket 会被本机 HTTP 代理劫持，必须剥离代理变量
    isolateProxy: true,
    // 过滤掉缺失原生插件时输出的 MissingPluginException 噪声日志
    filterOutput: (out) {
      final lines = out.split('\n');
      final filtered = lines.where((l) {
        if (l.contains('MissingPluginException')) return false;
        if (l.contains('plugins.flutter.io/')) return false;
        return true;
      });
      return filtered.join('\n').trim();
    },
  );

  stopwatch.stop();

  stdout.writeln('\n======================================================');
  stdout.writeln('📊 自检完成汇总 (总耗时: ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
  stdout.writeln('======================================================');

  bool allPassed = true;
  for (final res in results) {
    final icon = res.passed ? '✅ [PASS]' : '❌ [FAIL]';
    final duration = '${(res.durationMs / 1000).toStringAsFixed(1)}s';
    stdout.writeln('$icon ${res.name.padRight(36)} ($duration)');
    if (!res.passed) {
      allPassed = false;
      stderr.writeln('\n--- 失败详情 (${res.name}) ---');
      stderr.writeln(res.errorMessage);
      stderr.writeln('----------------------------------------\n');
    }
  }

  stdout.writeln('======================================================');
  if (allPassed) {
    stdout.writeln('🎉 全部检查通过！代码质量符合规范，可安全提交或部署。');
    if (!isFull && scope == null) {
      stdout.writeln(
        '⚠️ 极速模式仅覆盖 ${kFastTestSuites.length}/${_countTestSuites()} 个测试套件；'
        '改动了 speech/vision/llm/server 请改用 --scope <域> 或 --full',
      );
    }
    exit(0);
  } else {
    stderr.writeln('❌ 存在未通过检查项，请根据上述提示修复后重试。');
    exit(1);
  }
}

/// 自动检测并同步构建 Web 控制台生成物
///
/// 直接比对“期望内容”与生成物内容，而非 mtime：时钟回拨 / git checkout /
/// mtime 恰好相等都不会再漏判。
Future<void> _autoSyncWebConsole() async {
  final indexFile = File('web_console/index.html');
  final dartFile = File('lib/services/automation/web_console_html.dart');

  if (!indexFile.existsSync()) return;

  bool needsSync = true;
  if (dartFile.existsSync()) {
    try {
      final expectedHtml = assembleWebConsoleHtml(baseDir: 'web_console');
      needsSync = !dartFile.readAsStringSync().contains(expectedHtml);
    } catch (_) {
      needsSync = true;
    }
  }

  if (needsSync) {
    stdout.write('⚡ 检测到 Web 控制台源文件有更新或未同步，自动触发构建... ');
    final result = await Process.run(
      'dart',
      ['run', 'tool/build_web_console.dart'],
      runInShell: true,
    );
    if (result.exitCode == 0) {
      stdout.writeln('✅ 构建同步完成\n');
    } else {
      stdout.writeln('❌ 构建同步异常:\n${result.stderr}\n');
    }
  }
}

Future<void> _autoSyncAppSettings() async {
  final domainConfigsFile = File('lib/core/models/domain_configs.dart');
  final appSettingsGFile = File('lib/core/models/app_settings.g.dart');

  if (!domainConfigsFile.existsSync()) return;

  bool needsSync = true;
  if (appSettingsGFile.existsSync()) {
    try {
      final expectedG = generateAppSettingsCode(domainConfigsFile.readAsStringSync());
      needsSync = expectedG.trim() != appSettingsGFile.readAsStringSync().trim();
    } catch (_) {
      needsSync = true;
    }
  }

  if (needsSync) {
    stdout.write('⚡ 检测到领域配置源文件有更新或未同步，自动触发门面构建... ');
    final result = await Process.run(
      'dart',
      ['run', 'tool/build_settings.dart'],
      runInShell: true,
    );
    if (result.exitCode == 0) {
      stdout.writeln('✅ 门面同步完成\n');
    } else {
      stdout.writeln('❌ 门面同步异常:\n${result.stderr}\n');
    }
  }
}

/// 是否检测到会被 flutter_tester 误用的代理环境变量
bool _proxyEnvDetected() {
  return Platform.environment.keys.any((k) => kProxyEnvKeys.contains(k.toLowerCase()));
}

/// 构造剥离代理变量的子进程环境。
///
/// `Process.run` 的 `environment` 只能追加/覆盖、无法删除父进程变量，因此这里
/// 显式复制一份 `Platform.environment`、剔除代理键，并配合
/// `includeParentEnvironment: false` 使用。未检测到代理时返回 null（直接继承）。
Map<String, String>? _envWithoutProxy() {
  final env = <String, String>{};
  var stripped = false;
  Platform.environment.forEach((key, value) {
    if (kProxyEnvKeys.contains(key.toLowerCase())) {
      stripped = true;
    } else {
      env[key] = value;
    }
  });
  if (!stripped) return null;
  env['NO_PROXY'] = '127.0.0.1,localhost';
  env['no_proxy'] = '127.0.0.1,localhost';
  return env;
}

/// 统计 test/ 下实际的测试套件数量（不硬编码）
int _countTestSuites() {
  final dir = Directory('test');
  if (!dir.existsSync()) return 0;
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('_test.dart'))
      .length;
}

class _CheckItem {
  final String name;
  final bool passed;
  final int durationMs;
  final String errorMessage;

  _CheckItem({
    required this.name,
    required this.passed,
    required this.durationMs,
    required this.errorMessage,
  });
}

Future<void> _runStep({
  required String name,
  required String command,
  required List<String> args,
  required List<_CheckItem> results,
  VoidCallback? onSuccess,
  String Function(String output)? filterOutput,
  bool isolateProxy = false,
}) async {
  stdout.write('⏳ 正在执行: $name ... ');
  final sw = Stopwatch()..start();

  final environment = isolateProxy ? _envWithoutProxy() : null;

  try {
    final result = await Process.run(
      command,
      args,
      runInShell: true,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    sw.stop();

    if (result.exitCode == 0) {
      stdout.writeln('✅ 通过 (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
      if (onSuccess != null) onSuccess();
      results.add(_CheckItem(
        name: name,
        passed: true,
        durationMs: sw.elapsedMilliseconds,
        errorMessage: '',
      ));
    } else {
      stdout.writeln('❌ 失败 (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
      String rawErr = '${result.stdout}\n${result.stderr}'.trim();
      if (filterOutput != null) {
        rawErr = filterOutput(rawErr);
      }
      results.add(_CheckItem(
        name: name,
        passed: false,
        durationMs: sw.elapsedMilliseconds,
        errorMessage: rawErr,
      ));
    }
  } catch (e) {
    sw.stop();
    stdout.writeln('❌ 异常 (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
    results.add(_CheckItem(
      name: name,
      passed: false,
      durationMs: sw.elapsedMilliseconds,
      errorMessage: e.toString(),
    ));
  }
}

typedef VoidCallback = void Function();
