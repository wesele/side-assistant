import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/ports/llm_tool.dart';
import '../web_search_service.dart';

/// 联网搜索工具适配器 (WebSearchTool)
///
/// 封装 WebSearchService，为 LLM 提供联网事实检索能力。
class WebSearchTool implements LlmTool {
  final WebSearchService searchService;

  WebSearchTool({WebSearchService? searchService})
      : searchService = searchService ?? WebSearchService();

  @override
  String get name => 'web_search';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'web_search',
      'description':
          'Search the web for real-time, up-to-date, or factual information (such as news, weather, current events, latest releases, or facts you are unsure about).',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search keywords or query string.',
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
    return settings.enableWebSearch;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    final query = extractQuery(rawArguments);
    if (query.isEmpty) {
      return '搜索关键词为空，无法执行联网搜索。';
    }
    return searchService.searchAndFormat(query);
  }

  /// 健壮提取 query 关键词（支持完整 JSON、扁平 Map 或正则容错）
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
}
