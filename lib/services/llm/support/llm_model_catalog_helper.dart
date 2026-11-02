import 'dart:convert';
import 'package:http/http.dart' as http;

/// 大模型清单获取与思考参数推断辅助工具 (LlmModelCatalogHelper)
class LlmModelCatalogHelper {
  /// 根据模型名称自动推断关闭思考所适用的 API 请求参数
  static Map<String, dynamic> getThinkingDisableParams(String modelName) {
    final name = modelName.trim().toLowerCase();

    // 1. Qwen / QwQ 系列 (vLLM / DashScope / SiliconFlow 等兼容参数)
    if (name.contains('qwen') || name.contains('qwq')) {
      return {
        'enable_thinking': false,
        'chat_template_kwargs': {
          'enable_thinking': false,
        },
      };
    }

    // 2. OpenAI 推理系列 (o1 / o3 / o4 / gpt-5 / gpt-6) 与 Gemini 系列
    final isOpenAiReasoning = RegExp(r'\b(o1|o3|o4|gpt-5|gpt-6)\b').hasMatch(name) ||
        name.contains('o1-') ||
        name.contains('o3-') ||
        name.contains('o4-') ||
        name.startsWith('o1') ||
        name.startsWith('o3') ||
        name.startsWith('o4');
    if (isOpenAiReasoning || name.contains('gemini')) {
      return {
        'reasoning_effort': 'none',
      };
    }

    // 3. DeepSeek、Claude、GLM、Kimi、Doubao 及行业标准格式
    return {
      'thinking': {
        'type': 'disabled',
      },
    };
  }

  /// 从指定的 OpenAI 兼容 API 获取可用模型列表 (GET /models)
  static Future<List<String>> fetchAvailableModels({
    required String baseUrl,
    String? apiKey,
    http.Client? client,
  }) async {
    final cleanBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanBaseUrl.isEmpty) {
      return [];
    }
    final uri = Uri.parse('$cleanBaseUrl/models');
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(uri, headers: headers).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final models = <String>[];
        List<dynamic>? rawList;
        if (decoded is Map<String, dynamic>) {
          if (decoded['data'] is List) {
            rawList = decoded['data'] as List;
          } else if (decoded['models'] is List) {
            rawList = decoded['models'] as List;
          }
        } else if (decoded is List) {
          rawList = decoded;
        }
        if (rawList != null) {
          for (final item in rawList) {
            if (item is Map) {
              final id = item['id']?.toString() ?? item['name']?.toString();
              if (id != null && id.trim().isNotEmpty) {
                models.add(id.trim());
              }
            } else if (item is String && item.trim().isNotEmpty) {
              models.add(item.trim());
            }
          }
        }
        final uniqueModels = models.toSet().toList()..sort();
        return uniqueModels;
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }
}
