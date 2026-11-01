import 'dart:async';
import 'dart:typed_data';

import '../models/app_settings.dart';

/// 大语言模型工具执行上下文 (LlmToolContext)
///
/// 携带请求级运行时依赖（如相机实时抓拍回调、现场照片回传通知、当前会话标识等），
/// 严格遵循纯 Dart 无头规范（零 `dart:ui` / `package:flutter` 依赖）。
class LlmToolContext {
  /// 实时拍照回调（由具体环境注入；如若客户端不支持或当前未连接相机则为 null）
  final Future<Uint8List?> Function()? onCapturePhoto;

  /// 当工具执行成功生成或截获图片二进制流时触发的回调，供上层将图片注入消息上下文
  final void Function(Uint8List photoBytes)? onPhotoCaptured;

  /// 当前会话标识（可选）
  final String? sessionId;

  /// 额外可扩展上下文属性
  final Map<String, dynamic> extra;

  const LlmToolContext({
    this.onCapturePhoto,
    this.onPhotoCaptured,
    this.sessionId,
    this.extra = const {},
  });

  /// 浅拷贝并支持选择性重载上下文参数
  LlmToolContext copyWith({
    Future<Uint8List?> Function()? onCapturePhoto,
    void Function(Uint8List photoBytes)? onPhotoCaptured,
    String? sessionId,
    Map<String, dynamic>? extra,
  }) {
    return LlmToolContext(
      onCapturePhoto: onCapturePhoto ?? this.onCapturePhoto,
      onPhotoCaptured: onPhotoCaptured ?? this.onPhotoCaptured,
      sessionId: sessionId ?? this.sessionId,
      extra: extra ?? this.extra,
    );
  }
}

/// 大模型业务工具契约接口 (LLM Tool Contract)
///
/// 所有供大语言模型调用的 Function Calling 工具均需实现此接口。
abstract interface class LlmTool {
  /// 工具全局唯一名称（例如 'web_search', 'lightrag_query', 'capture_photo'）
  String get name;

  /// OpenAI Function Calling 规范的定义 Schema
  /// 格式包含: `{'type': 'function', 'function': {'name': ..., 'description': ..., 'parameters': ...}}`
  Map<String, dynamic> get definition;

  /// 判断该工具在当前全局配置与请求上下文中是否处于启用状态
  bool isEnabled(AppSettings settings, {LlmToolContext? context});

  /// 执行工具逻辑，入参为大模型输出的原始字符串参数（通常为 JSON），返回纯文本供大模型理解
  Future<String> execute(String rawArguments, {LlmToolContext? context});
}

/// 动态工具注册中心 (LlmToolRegistry)
///
/// 负责业务工具的集中注册、动态按需发现与统一分发执行。
class LlmToolRegistry {
  final Map<String, LlmTool> _tools = {};

  LlmToolRegistry([List<LlmTool>? initialTools]) {
    if (initialTools != null) {
      for (final tool in initialTools) {
        register(tool);
      }
    }
  }

  /// 注册工具；若已存在同名工具则自动覆盖更新
  void register(LlmTool tool) {
    _tools[tool.name] = tool;
  }

  /// 批量注册工具
  void registerAll(Iterable<LlmTool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// 注销指定名称的工具，返回被移除的工具实例（若存在）
  LlmTool? unregister(String name) {
    return _tools.remove(name);
  }

  /// 获取指定工具实例
  LlmTool? getTool(String name) => _tools[name];

  /// 操作符重载，等同于 [getTool]
  LlmTool? operator [](String name) => _tools[name];

  /// 是否包含指定工具
  bool hasTool(String name) => _tools.containsKey(name);

  /// 当前已注册的所有工具名称
  Iterable<String> get toolNames => _tools.keys;

  /// 当前已注册的所有工具列表
  Iterable<LlmTool> get tools => _tools.values;

  /// 清空注册表
  void clear() => _tools.clear();

  /// 获取当前配置与上下文下所有已启用的工具 Schema 列表
  List<Map<String, dynamic>> getEnabledDefinitions(
    AppSettings settings, {
    LlmToolContext? context,
  }) {
    return _tools.values
        .where((tool) => tool.isEnabled(settings, context: context))
        .map((tool) => tool.definition)
        .toList();
  }

  /// 判断某工具当前是否处于可用状态
  bool isToolEnabled(
    String toolName,
    AppSettings settings, {
    LlmToolContext? context,
  }) {
    final tool = _tools[toolName];
    if (tool == null) return false;
    return tool.isEnabled(settings, context: context);
  }

  /// 根据工具名动态调度执行
  Future<String> execute(
    String toolName,
    String rawArguments, {
    LlmToolContext? context,
  }) async {
    final tool = _tools[toolName];
    if (tool == null) {
      return 'Unsupported tool: $toolName';
    }
    return tool.execute(rawArguments, context: context);
  }
}
