import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/ports/llm_tool.dart';
import 'custom_tool_manager.dart';

/// 调用持久化自定义工具的大模型适配器 (CallCustomTool)
///
/// 允许大模型直接执行已注册到本地的自定义工具（如定时闹钟、查询脚本等）。
class CallCustomTool implements LlmTool {
  final CustomToolManager manager;
  final AppSettings Function()? settingsResolver;

  CallCustomTool({
    CustomToolManager? toolManager,
    this.settingsResolver,
  }) : manager = toolManager ?? CustomToolManager.instance;

  @override
  String get name => 'call_custom_tool';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'call_custom_tool',
      'description': '调用已注册的持久化自定义工具（如定时闹钟、周期提醒、本地系统脚本等）。调用前请确保该工具存在于已注册工具列表中。',
      'parameters': {
        'type': 'object',
        'properties': {
          'tool_name': {
            'type': 'string',
            'description': '要调用的自定义工具唯一英文名称（必须与系统提示词中已注册工具列表中的名称一致）。',
          },
          'arguments': {
            'type': 'object',
            'description': '传递给该工具的输入参数对象或键值对。',
          },
        },
        'required': ['tool_name'],
      },
    },
  };

  @override
  Map<String, dynamic> get definition => toolDefinition;

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) {
    return settings.enableOpenCode;
  }

  /// 提取用于 UI 状态展示的工具名称
  static String extractToolSummary(String rawArguments) {
    final trimmed = rawArguments.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final val =
            decoded['tool_name'] ?? decoded['toolName'] ?? decoded['name'];
        if (val != null) return val.toString().trim();
      }
    } catch (_) {
      final match = RegExp(r'"(?:tool_name|toolName|name)"\s*:\s*"([^"]+)"')
          .firstMatch(trimmed);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }
    return trimmed;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    final trimmed = rawArguments.trim();
    String toolName = '';
    String argsJson = '{}';

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        toolName = (decoded['tool_name'] ??
                decoded['toolName'] ??
                decoded['name'] ??
                '')
            .toString()
            .trim();
        final argsObj = decoded['arguments'] ?? decoded['args'];
        if (argsObj is Map || argsObj is List) {
          argsJson = jsonEncode(argsObj);
        } else if (argsObj is String && argsObj.trim().isNotEmpty) {
          argsJson = argsObj.trim();
        } else if (argsObj == null) {
          final otherKeys = Map<String, dynamic>.from(decoded)
            ..remove('tool_name')
            ..remove('toolName')
            ..remove('name');
          if (otherKeys.isNotEmpty) {
            argsJson = jsonEncode(otherKeys);
          }
        }
      }
    } catch (_) {
      toolName = extractToolSummary(trimmed);
    }

    if (toolName.isEmpty) {
      return '缺少必需的工具名称 (tool_name)，无法调用自定义工具。';
    }

    final settings = settingsResolver?.call();
    return manager.executeCustomTool(toolName, argsJson, settings: settings);
  }
}
