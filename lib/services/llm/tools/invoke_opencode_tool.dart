import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/ports/llm_tool.dart';
import 'custom_tool_manager.dart';

/// 调用 OpenCode 生成代码或就地执行任务的大模型适配器 (InvokeOpenCodeTool)
///
/// 允许大模型通过 OpenCode 自主编写并运行代码，创建持久化工具或完成一次性复杂计算。
class InvokeOpenCodeTool implements LlmTool {
  final CustomToolManager manager;
  final AppSettings Function()? settingsResolver;

  InvokeOpenCodeTool({
    CustomToolManager? toolManager,
    this.settingsResolver,
  }) : manager = toolManager ?? CustomToolManager.instance;

  @override
  String get name => 'invoke_opencode';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'invoke_opencode',
      'description': '利用 OpenCode 自动化编写并执行代码。支持两种模式：'
          '1) persistent (持久化工具)：编写可复用工具（如闹钟、定时器、特定功能脚本），保存至工具库供以后直接调用；'
          '2) temporary (一次性任务)：编写临时脚本就地解决复杂的数学计算、数据转换或一次性探索任务，执行后自动销毁。',
      'parameters': {
        'type': 'object',
        'properties': {
          'task_description': {
            'type': 'string',
            'description': '详细的任务描述与需求说明，包含输入输出规格与业务逻辑。',
          },
          'persistence': {
            'type': 'string',
            'enum': ['persistent', 'temporary'],
            'description':
                '工具生命周期类型："persistent" 为持久化可复用工具；"temporary" 为一次性就地执行任务。',
          },
          'tool_name': {
            'type': 'string',
            'description':
                '持久化工具的英文唯一标识（仅 persistent 模式推荐填写，如 alarm_clock, pomodoro_timer）。',
          },
          'tool_summary': {
            'type': 'string',
            'description': '持久化工具的简明中文功能描述，用于注册到系统提示词供后续识别。',
          },
          'parameters_hint': {
            'type': 'string',
            'description': '参数提示说明（例如 "time: 触发时间 HH:mm, message: 提示词"）。',
          },
          'initial_arguments': {
            'type': 'object',
            'description': '首次创建并执行该工具时传入的具体参数。',
          },
        },
        'required': ['task_description', 'persistence'],
      },
    },
  };

  @override
  Map<String, dynamic> get definition => toolDefinition;

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) {
    return settings.enableOpenCode;
  }

  /// 提取用于 UI 状态展示的简短任务或工具摘要
  static String extractTaskSummary(String rawArguments) {
    final trimmed = rawArguments.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final toolName = decoded['tool_name'] ?? decoded['toolName'];
        if (toolName != null && toolName.toString().trim().isNotEmpty) {
          return toolName.toString().trim();
        }
        final summary = decoded['tool_summary'] ??
            decoded['task_description'] ??
            decoded['taskDescription'];
        if (summary != null) {
          final s = summary.toString().trim();
          return s.length > 30 ? '${s.substring(0, 30)}...' : s;
        }
      }
    } catch (_) {
      final match = RegExp(
        r'"(?:tool_name|tool_summary|task_description)"\s*:\s*"([^"]+)"',
      ).firstMatch(trimmed);
      if (match != null) {
        final s = match.group(1)!.trim();
        return s.length > 30 ? '${s.substring(0, 30)}...' : s;
      }
    }
    return trimmed.length > 30 ? '${trimmed.substring(0, 30)}...' : trimmed;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    final trimmed = rawArguments.trim();
    String taskDescription = '';
    String persistence = 'temporary';
    String? toolName;
    String? toolSummary;
    String? parametersHint;
    String? initialArguments;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        taskDescription =
            (decoded['task_description'] ?? decoded['taskDescription'] ?? '')
                .toString()
                .trim();
        persistence = (decoded['persistence'] ?? 'temporary').toString().trim();
        final rawToolName = decoded['tool_name'] ?? decoded['toolName'];
        if (rawToolName != null && rawToolName.toString().trim().isNotEmpty) {
          toolName = rawToolName.toString().trim();
        }
        final rawSummary = decoded['tool_summary'] ?? decoded['toolSummary'];
        if (rawSummary != null && rawSummary.toString().trim().isNotEmpty) {
          toolSummary = rawSummary.toString().trim();
        }
        final rawHint = decoded['parameters_hint'] ?? decoded['parametersHint'];
        if (rawHint != null && rawHint.toString().trim().isNotEmpty) {
          parametersHint = rawHint.toString().trim();
        }
        final rawInitArgs =
            decoded['initial_arguments'] ?? decoded['initialArguments'];
        if (rawInitArgs is Map || rawInitArgs is List) {
          initialArguments = jsonEncode(rawInitArgs);
        } else if (rawInitArgs != null) {
          initialArguments = rawInitArgs.toString();
        }
      }
    } catch (e) {
      return '参数解析失败，无法调用 invoke_opencode: $e';
    }

    if (taskDescription.isEmpty) {
      return '缺少必需的任务描述 (task_description)，无法调用 invoke_opencode。';
    }

    final settings = settingsResolver?.call();
    return manager.invokeOpenCode(
      taskDescription: taskDescription,
      persistence: persistence,
      toolName: toolName,
      toolSummary: toolSummary,
      parametersHint: parametersHint,
      initialArguments: initialArguments,
      settings: settings,
    );
  }
}
