import 'dart:convert';

/// 流式工具调用累积容器 (AccumulatedToolCall)
class AccumulatedToolCall {
  String id;
  String name;
  final StringBuffer argumentsBuffer = StringBuffer();

  AccumulatedToolCall({
    required this.id,
    required this.name,
  });

  String get arguments => argumentsBuffer.toString();

  Map<String, dynamic> toOpenAiMap() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': arguments,
        },
      };
}

/// 文本内联工具调用解析器 (TextToolCallParser)
///
/// 解析 DeepSeek DSML 或通用 XML `<tool_call>` 标签，支持流式截断与参数重构。
class TextToolCallParser {
  static final RegExp textToolStartRegex = RegExp(
    r'<[｜|\s]*DSML|<\s*tool_call\b|<\s*function_calls\b',
    caseSensitive: false,
  );

  static const List<String> _potentialToolTagPrefixes = [
    '<｜｜dsml',
    '<｜dsml',
    '<|dsml',
    '<||dsml',
    '<tool_call',
    '<function_calls',
  ];

  /// 检查缓冲末尾是否可能是尚未接收完整的工具标签前缀（如 "<"、"<｜｜"、"<tool_"）
  /// 返回该后缀起始下标；若不存在则返回 -1。
  static int findPotentialToolTagSuffixIndex(String buffer) {
    final lastLt = buffer.lastIndexOf('<');
    if (lastLt == -1) return -1;
    final tail = buffer.substring(lastLt).toLowerCase();
    if (tail.length > 16) return -1;
    for (final p in _potentialToolTagPrefixes) {
      if (p.startsWith(tail)) {
        return lastLt;
      }
    }
    return -1;
  }

  /// 从模型输出的 DSML 或 `<tool_call>` 文本标签中提取工具调用列表
  static List<AccumulatedToolCall> parseTextToolCalls(
    String text, {
    int round = 0,
  }) {
    final results = <AccumulatedToolCall>[];
    if (text.isEmpty) return results;

    // 1. 解析 DeepSeek DSML 格式：
    // <｜｜DSML｜｜ invoke name="web_search">
    // <｜｜DSML｜｜ parameter name="query" string="true">...</｜｜DSML｜｜ parameter>
    // </｜｜DSML｜｜ invoke>
    final dsmlInvokes = RegExp(
      r'<[｜|\s]*DSML[｜|\s]*invoke\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/[｜|\s]*DSML[｜|\s]*invoke>',
      caseSensitive: false,
    ).allMatches(text);

    var idx = 0;
    for (final m in dsmlInvokes) {
      final fnName = (m.group(1) ?? 'web_search').trim();
      final body = m.group(2) ?? '';
      final params = <String, dynamic>{};

      final paramMatches = RegExp(
        r'<[｜|\s]*DSML[｜|\s]*parameter\s+name="([^"]+)"[^>]*>([\s\S]*?)<\/[｜|\s]*DSML[｜|\s]*parameter>',
        caseSensitive: false,
      ).allMatches(body);

      for (final pm in paramMatches) {
        final pName = (pm.group(1) ?? '').trim();
        final pVal = (pm.group(2) ?? '').trim();
        if (pName.isNotEmpty) {
          params[pName] = pVal;
        }
      }

      final call = AccumulatedToolCall(
        id: 'dsml_${round}_$idx',
        name: fnName,
      );
      call.argumentsBuffer.write(
        params.isNotEmpty ? jsonEncode(params) : body.trim(),
      );
      results.add(call);
      idx++;
    }

    if (results.isNotEmpty) {
      return results;
    }

    // 2. 解析通用 <tool_call>{"name": "web_search", "arguments": ...}</tool_call> 格式
    final xmlToolCalls = RegExp(
      r'<tool_call\b[^>]*>([\s\S]*?)<\/tool_call>',
      caseSensitive: false,
    ).allMatches(text);

    for (final m in xmlToolCalls) {
      final inner = (m.group(1) ?? '').trim();
      if (inner.isEmpty) continue;
      String fnName = 'web_search';
      String argsStr = inner;
      try {
        final decoded = jsonDecode(inner);
        if (decoded is Map) {
          fnName = decoded['name']?.toString() ?? 'web_search';
          final rawArgs = decoded['arguments'] ?? decoded['parameters'];
          if (rawArgs is String) {
            argsStr = rawArgs;
          } else if (rawArgs != null) {
            argsStr = jsonEncode(rawArgs);
          }
        }
      } catch (_) {}

      final call = AccumulatedToolCall(
        id: 'xml_${round}_$idx',
        name: fnName,
      );
      call.argumentsBuffer.write(argsStr);
      results.add(call);
      idx++;
    }

    return results;
  }

  /// 剥离文本中的 DSML 或 `<tool_call>` 标签块，只保留标签之前的正常文本
  static String stripTextToolCalls(String text) {
    final match = textToolStartRegex.firstMatch(text);
    if (match != null) {
      return text.substring(0, match.start).trim();
    }
    return text.trim();
  }

  /// 检查服务端返回的错误是否为不支持 Function Call / Tool
  static bool isToolsUnsupportedError(String errorBody) {
    final lower = errorBody.toLowerCase();
    return (lower.contains('tool') || lower.contains('function')) &&
        (lower.contains('not support') ||
            lower.contains('unsupported') ||
            lower.contains('unknown field') ||
            lower.contains('invalid parameter'));
  }
}
