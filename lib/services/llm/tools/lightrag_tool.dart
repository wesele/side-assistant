import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/ports/knowledge_port.dart';
import '../../../core/ports/llm_tool.dart';

/// LightRAG 个人知识库检索工具适配器 (LightRagTool)
///
/// 面向 [KnowledgePort] 抽象接口编程，为 LLM 提供知识库问答检索能力。
class LightRagTool implements LlmTool {
  final KnowledgePort? knowledgePort;

  LightRagTool({this.knowledgePort});

  @override
  String get name => 'lightrag_query';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'lightrag_query',
      'description':
          '查询主人浩哥的个人知识库 LightRAG（包含主人的各类个人信息以及历史对话记录）。当用户询问关于他自己的信息、过去聊过的内容、偏好、安排等你不确定的事时调用。只读查询。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '要查询的关键词或问题。',
          },
          'mode': {
            'type': 'string',
            'enum': ['mix', 'local', 'global', 'naive'],
            'description':
                'mix=图谱+向量混合（默认推荐）；local=实体细节；global=全局摘要；naive=纯向量。',
          },
        },
        'required': ['query'],
      },
    },
  };

  @override
  Map<String, dynamic> get definition => toolDefinition;

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) {
    return settings.enableLightRag &&
        knowledgePort != null &&
        settings.lightRagBaseUrl.trim().isNotEmpty;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    if (knowledgePort == null) {
      return 'LightRAG 服务未配置或未启用。';
    }
    final query = extractQuery(rawArguments);
    if (query.isEmpty) {
      return '查询内容为空。';
    }
    final mode = extractMode(rawArguments);
    return knowledgePort!.queryContext(query, mode: mode);
  }

  static String extractQuery(String rawArguments) {
    final trimmed = rawArguments.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final q = decoded['query'] ?? decoded['q'] ?? decoded['keyword'];
        if (q != null) return q.toString().trim();
      } else if (decoded is String) {
        return decoded.trim();
      }
    } catch (_) {
      final match =
          RegExp(r'"(?:query|q|keyword)"\s*:\s*"([^"]+)"').firstMatch(trimmed);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }
    return trimmed;
  }

  static String extractMode(String rawArguments) {
    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map && decoded['mode'] is String) {
        final m = decoded['mode'] as String;
        return m == 'hybrid' ? 'mix' : m;
      }
    } catch (_) {}
    return 'mix';
  }
}
