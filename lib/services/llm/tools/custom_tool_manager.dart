import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/models/custom_tool_manifest.dart';
import '../../../core/platform/storage_bridge.dart';

/// 进程执行结果数据类
class CustomToolProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const CustomToolProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });
}

/// 进程执行器函数签名（用于依赖注入与单测隔离）
typedef CustomToolProcessRunner = Future<CustomToolProcessResult> Function({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required Map<String, String> environment,
  String? stdinText,
  required Duration timeout,
});

/// 自定义工具与 OpenCode 管理器 (CustomToolManager)
///
/// 负责持久化自定义工具的清单扫描、文件管理、受限执行以及 OpenCode 代码生成工具调度。
class CustomToolManager {
  /// 全局共享单例
  static CustomToolManager instance = CustomToolManager();

  /// 解析当前代码智能体的显示名称（如 OpenCode 或 Hermes）
  static String resolveAgentDisplayName(AppSettings? settings) {
    final provider = settings?.codeAgentProvider.trim().toLowerCase() ??
        AppConstants.defaultCodeAgentProvider;
    return provider == AppConstants.codeAgentProviderHermes
        ? 'Hermes'
        : 'OpenCode';
  }

  /// 解析当前代码智能体的实际 CLI 执行命令
  static String resolveEffectiveCliCommand(AppSettings? settings) {
    final provider = settings?.codeAgentProvider.trim().toLowerCase() ??
        AppConstants.defaultCodeAgentProvider;
    if (provider == AppConstants.codeAgentProviderHermes) {
      final raw = settings?.hermesCommand.trim() ?? '';
      final cmd = raw.isEmpty ? AppConstants.defaultHermesCommand : raw;
      return (cmd == 'hermes') ? 'hermes chat -Q --query-file -' : cmd;
    }
    final raw = settings?.openCodeCommand.trim() ?? '';
    final cmd = raw.isEmpty ? AppConstants.defaultOpenCodeCommand : raw;
    return (cmd == 'opencode') ? 'opencode run' : cmd;
  }

  final Directory Function()? _customToolsDirResolver;
  final Directory Function()? _tempBaseDirResolver;
  final CustomToolProcessRunner _processRunner;

  CustomToolManager({
    Directory Function()? customToolsDirResolver,
    Directory Function()? tempBaseDirResolver,
    CustomToolProcessRunner? processRunner,
  })  : _customToolsDirResolver = customToolsDirResolver,
        _tempBaseDirResolver = tempBaseDirResolver,
        _processRunner = processRunner ?? _defaultProcessRunner;

  /// 持久化自定义工具存储根目录
  Directory get customToolsDir =>
      _customToolsDirResolver?.call() ??
      Directory(
        p.join(
          StorageBridge.resolveBaseDataDir().path,
          'support',
          'custom_tools',
        ),
      );

  /// 临时任务执行根目录
  Directory get tempBaseDir =>
      _tempBaseDirResolver?.call() ??
      Directory(p.join(Directory.systemTemp.path, 'side_assistant'));

  /// 默认进程执行器（使用纯 Dart Process API，自动管理标准输入并兜底防僵尸进程）
  static Future<CustomToolProcessResult> _defaultProcessRunner({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    String? stdinText,
    required Duration timeout,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );

    if (stdinText != null && stdinText.isNotEmpty) {
      process.stdin.write(stdinText);
      await process.stdin.flush();
    }
    await process.stdin.close();

    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutFuture = process.stdout.transform(decoder).join();
    final stderrFuture = process.stderr.transform(decoder).join();
    final exitCodeFuture = process.exitCode;

    final results = await Future.wait([
      stdoutFuture,
      stderrFuture,
      exitCodeFuture,
    ]).timeout(
      timeout,
      onTimeout: () {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {
          process.kill();
        }
        throw TimeoutException('Process execution timed out after $timeout');
      },
    );

    return CustomToolProcessResult(
      stdout: results[0] as String,
      stderr: results[1] as String,
      exitCode: results[2] as int,
    );
  }

  /// 同步扫描已注册的所有持久化自定义工具
  List<CustomToolManifest> listToolsSync() {
    final baseDir = customToolsDir;
    if (!baseDir.existsSync()) {
      return <CustomToolManifest>[];
    }

    final tools = <CustomToolManifest>[];
    final entities = baseDir.listSync();

    for (final entity in entities) {
      if (entity is! Directory) continue;
      final toolDir = entity;
      final toolJsonFile = File(p.join(toolDir.path, 'tool.json'));
      if (!toolJsonFile.existsSync()) continue;

      try {
        final content = toolJsonFile.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) continue;

        final manifest = CustomToolManifest.fromMap(decoded);
        if (CustomToolManifest.isValidToolName(manifest.name) &&
            manifest.command.trim().isNotEmpty) {
          tools.add(manifest);
        }
      } catch (_) {
        // 忽略畸变 tool.json
      }
    }

    tools.sort((a, b) => a.name.compareTo(b.name));
    return tools;
  }

  /// 删除指定的持久化工具，返回是否删除成功
  bool deleteTool(String name) {
    final trimmed = name.trim();
    if (!CustomToolManifest.isValidToolName(trimmed)) {
      return false;
    }

    final toolDir = Directory(p.join(customToolsDir.path, trimmed));
    if (!toolDir.existsSync()) {
      return false;
    }

    try {
      toolDir.deleteSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 构造执行工具脚本时的环境变量上下文
  Map<String, String> buildToolEnvironment({
    required String workingDir,
    required String argsJson,
    AppSettings? settings,
  }) {
    final port = Platform.environment['SIDE_ASSISTANT_PORT'] ?? '19823';
    final env = <String, String>{
      'TOOL_ARGS_JSON': argsJson,
      'SIDE_ASSISTANT_TOOL_DIR': workingDir,
      'SIDE_ASSISTANT_DATA_DIR': StorageBridge.resolveBaseDataDir().path,
      'SIDE_ASSISTANT_API_URL': 'http://127.0.0.1:$port',
      'SIDE_ASSISTANT_SPEAK_URL': 'http://127.0.0.1:$port/api/speak-text',
      'SIDE_ASSISTANT_ACCESS_PASSWORD': settings?.webAccessPassword ?? '',
    };

    if (!Platform.isWindows) {
      final home = Platform.environment['HOME'] ?? '';
      final currentPath =
          Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin';
      if (home.isNotEmpty) {
        final extraPaths =
            '$home/.local/bin:$home/.npm-global/bin:$home/.opencode/bin:$home/.cargo/bin';
        env['PATH'] = '$extraPaths:$currentPath';
      }
    }

    return env;
  }

  /// 执行指定的持久化工具
  Future<String> executeCustomTool(
    String toolName,
    String rawArguments, {
    AppSettings? settings,
    Duration? timeout,
  }) async {
    final trimmedName = toolName.trim();
    if (!CustomToolManifest.isValidToolName(trimmedName)) {
      return '工具名称 "$trimmedName" 非法，仅支持 1-64 位的字母、数字、下划线及连字符。';
    }

    final toolDir = Directory(p.join(customToolsDir.path, trimmedName));
    final toolJsonFile = File(p.join(toolDir.path, 'tool.json'));
    if (!toolJsonFile.existsSync()) {
      return '未找到名为 "$trimmedName" 的持久化工具。请先检查系统提示词中的工具列表，或调用 invoke_opencode 创建该工具。';
    }

    final CustomToolManifest manifest;
    try {
      final decoded = jsonDecode(toolJsonFile.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        return '工具 "$trimmedName" 的 tool.json 格式错误，无法执行。';
      }
      manifest = CustomToolManifest.fromMap(decoded);
    } catch (e) {
      return '读取工具 "$trimmedName" 失败: $e';
    }

    final argsJson = rawArguments.trim().isEmpty ? '{}' : rawArguments.trim();
    final effectiveTimeout = timeout ??
        Duration(
          seconds: settings?.openCodeTimeoutSeconds ??
              AppConstants.defaultOpenCodeTimeoutSeconds,
        );

    final String executable;
    final List<String> arguments;
    if (Platform.isWindows) {
      executable = 'cmd';
      arguments = ['/c', manifest.command];
    } else {
      executable = 'sh';
      arguments = ['-c', manifest.command];
    }

    final env = buildToolEnvironment(
      workingDir: toolDir.path,
      argsJson: argsJson,
      settings: settings,
    );

    try {
      final result = await _processRunner(
        executable: executable,
        arguments: arguments,
        workingDirectory: toolDir.path,
        environment: env,
        stdinText: argsJson,
        timeout: effectiveTimeout,
      );

      final String output;
      if (result.exitCode == 0) {
        output = result.stdout.trim().isNotEmpty
            ? result.stdout.trim()
            : '[工具执行成功但未输出内容]';
      } else {
        final errText = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : (result.stdout.trim().isNotEmpty
                ? result.stdout.trim()
                : '未知退出码 ${result.exitCode}');
        output = '[工具执行失败，退出码: ${result.exitCode}]\n$errText';
      }

      if (output.length > 8000) {
        return '${output.substring(0, 8000)}\n...[输出过长，已截断]';
      }
      return output;
    } catch (e) {
      return '[工具执行异常: $e]';
    }
  }

  /// 封装调用 OpenCode / Hermes CLI
  Future<CustomToolProcessResult> _invokeOpenCodeCli({
    required String openCodeCmd,
    required String prompt,
    required String workingDir,
    required Map<String, String> environment,
    required Duration timeout,
    String provider = AppConstants.defaultCodeAgentProvider,
  }) async {
    final trimmedCmd = openCodeCmd.trim();
    final String cmdWithSub;
    if (provider == AppConstants.codeAgentProviderHermes) {
      cmdWithSub = (trimmedCmd == 'hermes')
          ? 'hermes chat -Q --query-file -'
          : trimmedCmd;
    } else {
      cmdWithSub = (trimmedCmd == 'opencode') ? 'opencode run' : trimmedCmd;
    }

    final String executable;
    final List<String> arguments;
    if (Platform.isWindows) {
      executable = 'cmd';
      arguments = ['/c', cmdWithSub];
    } else {
      executable = 'sh';
      arguments = ['-c', cmdWithSub];
    }

    return await _processRunner(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDir,
      environment: environment,
      stdinText: prompt,
      timeout: timeout,
    );
  }

  /// 调用 OpenCode 生成持久化工具或就地执行一次性任务
  Future<String> invokeOpenCode({
    required String taskDescription,
    required String persistence,
    String? toolName,
    String? toolSummary,
    String? parametersHint,
    String? initialArguments,
    AppSettings? settings,
    Duration? timeout,
  }) async {
    final isPersistent = persistence.trim().toLowerCase() == 'persistent';
    final provider = (settings?.codeAgentProvider.trim().toLowerCase() ==
            AppConstants.codeAgentProviderHermes)
        ? AppConstants.codeAgentProviderHermes
        : AppConstants.codeAgentProviderOpenCode;
    final agentName = resolveAgentDisplayName(settings);
    final openCodeCmd = (provider == AppConstants.codeAgentProviderHermes)
        ? ((settings?.hermesCommand.trim().isNotEmpty == true)
            ? settings!.hermesCommand.trim()
            : AppConstants.defaultHermesCommand)
        : ((settings?.openCodeCommand.trim().isNotEmpty == true)
            ? settings!.openCodeCommand.trim()
            : AppConstants.defaultOpenCodeCommand);
    final effectiveTimeout = timeout ??
        Duration(
          seconds: settings?.openCodeTimeoutSeconds ??
              AppConstants.defaultOpenCodeTimeoutSeconds,
        );

    if (isPersistent) {
      String safeToolName;
      final rawName = toolName?.trim() ?? '';
      if (rawName.isNotEmpty && CustomToolManifest.isValidToolName(rawName)) {
        safeToolName = rawName;
      } else if (rawName.isNotEmpty) {
        final sanitized =
            rawName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').toLowerCase();
        safeToolName = CustomToolManifest.isValidToolName(sanitized)
            ? sanitized
            : 'custom_tool_${DateTime.now().millisecondsSinceEpoch}';
      } else {
        safeToolName = 'custom_tool_${DateTime.now().millisecondsSinceEpoch}';
      }

      final toolDir = Directory(p.join(customToolsDir.path, safeToolName));
      if (!toolDir.existsSync()) {
        toolDir.createSync(recursive: true);
      }

      final safeSummary = (toolSummary != null && toolSummary.trim().isNotEmpty)
          ? toolSummary.trim()
          : taskDescription.trim();
      final safeHint = parametersHint?.trim() ?? '';
      final initialArgs =
          (initialArguments != null && initialArguments.trim().isNotEmpty)
              ? initialArguments.trim()
              : '{}';

      final prompt = StringBuffer()
        ..writeln('你正在为语音助手 SideAssistant 创建一个持久化可复用工具。')
        ..writeln('工具名称: $safeToolName')
        ..writeln('工具功能需求: $taskDescription')
        ..writeln()
        ..writeln('【执行要求】')
        ..writeln('1. 在当前工作目录 (${toolDir.path}) 下编写代码并生成持久化工具。')
        ..writeln('2. 必须在当前目录下生成并写入 tool.json 配置文件，格式如下：')
        ..writeln('   {')
        ..writeln('     "name": "$safeToolName",')
        ..writeln('     "summary": "$safeSummary",')
        ..writeln('     "parametersHint": "$safeHint",')
        ..writeln('     "command": "python3 run.py (或 bash run.sh)",')
        ..writeln('     "createdAt": "${DateTime.now().toIso8601String()}"')
        ..writeln('   }')
        ..writeln('3. 脚本实现规范：')
        ..writeln('   - 运行时从环境变量 TOOL_ARGS_JSON（或 stdin）读取输入参数 JSON。')
        ..writeln('   - 执行完成后向 stdout 打印简明 UTF-8 文本结果。')
        ..writeln('4. 语音播报联动（适合闹钟、定时器、提醒等需后台触发语音的场景）：')
        ..writeln(
            '   - 环境变量 SIDE_ASSISTANT_SPEAK_URL (例如 http://127.0.0.1:19823/api/speak-text) 可供调用。')
        ..writeln('   - 发送 POST JSON 请求 {"text": "播报内容"} 即可主动发声。')
        ..writeln(
            '   - 若环境变量 SIDE_ASSISTANT_ACCESS_PASSWORD 非空，需在 HTTP 请求头中附加 x-access-password。')
        ..writeln(
            '5. 编写完成后，立即在当前目录用初始参数执行/测试该工具 (initialArguments: $initialArgs)，并将最终结果打印到 stdout。');

      final env = buildToolEnvironment(
        workingDir: toolDir.path,
        argsJson: initialArgs,
        settings: settings,
      );

      try {
        final result = await _invokeOpenCodeCli(
          openCodeCmd: openCodeCmd,
          prompt: prompt.toString(),
          workingDir: toolDir.path,
          environment: env,
          timeout: effectiveTimeout,
          provider: provider,
        );

        final toolJsonFile = File(p.join(toolDir.path, 'tool.json'));
        if (!toolJsonFile.existsSync()) {
          // 兜底补全 tool.json 清单
          final candidateScripts = [
            ('run.py', 'python3 run.py'),
            ('main.py', 'python3 main.py'),
            ('run.sh', 'bash run.sh'),
            ('index.js', 'node index.js'),
          ];
          for (final candidate in candidateScripts) {
            final scriptFile = File(p.join(toolDir.path, candidate.$1));
            if (scriptFile.existsSync()) {
              final fallbackManifest = CustomToolManifest(
                name: safeToolName,
                summary: safeSummary,
                parametersHint: safeHint,
                command: candidate.$2,
                createdAt: DateTime.now().toIso8601String(),
              );
              toolJsonFile.writeAsStringSync(
                jsonEncode(fallbackManifest.toMap()),
              );
              break;
            }
          }
        }

        final bool created = toolJsonFile.existsSync();
        final stdOut = result.stdout.trim();
        final stdErr = result.stderr.trim();

        if (created) {
          final buffer = StringBuffer();
          buffer.writeln('持久化工具 "$safeToolName" 创建并注册成功。');
          if (stdOut.isNotEmpty) {
            buffer.writeln('\n执行输出:\n$stdOut');
          }
          if (result.exitCode != 0 && stdErr.isNotEmpty) {
            buffer.writeln('\n警告 (退出码 ${result.exitCode}):\n$stdErr');
          }
          return buffer.toString().trim();
        } else {
          final errMsg = stdErr.isNotEmpty
              ? stdErr
              : (stdOut.isNotEmpty
                  ? stdOut
                  : '$agentName 未生成 tool.json 且未找到可执行入口脚本。');
          return '[持久化工具创建失败，退出码: ${result.exitCode}]\n$errMsg';
        }
      } catch (e) {
        return '[调用 $agentName 异常: $e]';
      }
    } else {
      final tempDir = Directory(
        p.join(
          tempBaseDir.path,
          'opencode_tmp_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      if (!tempDir.existsSync()) {
        tempDir.createSync(recursive: true);
      }

      try {
        final initialArgs =
            (initialArguments != null && initialArguments.trim().isNotEmpty)
                ? initialArguments.trim()
                : '{}';
        final prompt = StringBuffer()
          ..writeln('你正在为语音助手 SideAssistant 执行一个一次性临时任务。')
          ..writeln('任务描述: $taskDescription')
          ..writeln('初始参数: $initialArgs')
          ..writeln()
          ..writeln('【执行要求】')
          ..writeln('1. 在当前临时目录 (${tempDir.path}) 下编写一次性脚本并立即执行解决该任务。')
          ..writeln('2. 将最终计算/处理结果简明清晰地输出到 stdout。')
          ..writeln(
              '3. 环境变量 SIDE_ASSISTANT_SPEAK_URL 及 SIDE_ASSISTANT_ACCESS_PASSWORD 可用（如有需要可主动触发语音播报）。');

        final env = buildToolEnvironment(
          workingDir: tempDir.path,
          argsJson: initialArgs,
          settings: settings,
        );

        final result = await _invokeOpenCodeCli(
          openCodeCmd: openCodeCmd,
          prompt: prompt.toString(),
          workingDir: tempDir.path,
          environment: env,
          timeout: effectiveTimeout,
          provider: provider,
        );

        if (result.exitCode == 0) {
          return result.stdout.trim().isNotEmpty
              ? result.stdout.trim()
              : '[一次性任务执行完成，未输出内容]';
        } else {
          final err = result.stderr.trim().isNotEmpty
              ? result.stderr.trim()
              : (result.stdout.trim().isNotEmpty
                  ? result.stdout.trim()
                  : '未知退出码 ${result.exitCode}');
          return '[一次性任务执行失败，退出码: ${result.exitCode}]\n$err';
        }
      } catch (e) {
        return '[调用 $agentName 一次性任务异常: $e]';
      } finally {
        try {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    }
  }
}
