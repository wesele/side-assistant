import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/models/app_settings.dart';
import '../../core/models/chat_message.dart';

class LlmService {
  final AppSettings settings;

  LlmService({required this.settings});

  /// 发送上下文至 OpenAI 兼容 API 并流式返回文本 token
  Stream<String> sendChatStream({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
  }) async* {
    final baseUrl = settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$baseUrl/chat/completions');

    final messages = <Map<String, dynamic>>[];

    // 1. 系统提示词 (用于控制大模型回答风格)
    if (settings.systemPrompt.trim().isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': settings.systemPrompt.trim(),
      });
    }

    // 2. 携带当前 Session 内的完整上下文历史（按用户决策：不设限制全量发送）
    for (final msg in history) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        messages.add(msg.toOpenAiMessage());
      }
    }

    // 3. 当前最新用户指令
    messages.add({
      'role': 'user',
      'content': newUserContent,
    });

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    if (settings.openAiApiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${settings.openAiApiKey}';
    }

    final convId = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : (history.isNotEmpty && history.last.sessionId != null)
            ? history.last.sessionId!
            : 'conv-${DateTime.now().millisecondsSinceEpoch}';

    request.body = jsonEncode({
      'model': settings.openAiModel.isNotEmpty ? settings.openAiModel : 'gpt-4o-mini',
      'messages': messages,
      'stream': true,
      'temperature': 0.7,
      'conversation_id': convId,
      'user': convId,
    });

    final client = http.Client();
    try {
      http.StreamedResponse streamedResponse = await client.send(request);

      if (streamedResponse.statusCode < 200 || streamedResponse.statusCode >= 300) {
        final errorBody = await streamedResponse.stream.bytesToString();
        if (errorBody.contains('11128') || errorBody.contains('conversation id missing')) {
          // 遇到上游渠道抖动拦截，延迟 800ms 重试一次
          await Future.delayed(const Duration(milliseconds: 800));
          final retryRequest = http.Request('POST', url);
          retryRequest.headers.addAll(request.headers);
          final freshConvId = 'wb-${DateTime.now().millisecondsSinceEpoch}';
          retryRequest.body = jsonEncode({
            'model': settings.openAiModel.isNotEmpty ? settings.openAiModel : 'gpt-4o-mini',
            'messages': messages,
            'stream': true,
            'temperature': 0.7,
            'conversation_id': freshConvId,
            'user': freshConvId,
          });
          streamedResponse = await client.send(retryRequest);
          if (streamedResponse.statusCode < 200 || streamedResponse.statusCode >= 300) {
            final secondErr = await streamedResponse.stream.bytesToString();
            throw Exception('LLM API Error ${streamedResponse.statusCode}: $secondErr');
          }
        } else {
          throw Exception('LLM API Error ${streamedResponse.statusCode}: $errorBody');
        }
      }

      final lines = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed == 'data: [DONE]') break;
        if (trimmed.startsWith('data: ')) {
          final jsonStr = trimmed.substring(6).trim();
          try {
            final data = jsonDecode(jsonStr) as Map<String, dynamic>;
            final choices = data['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map<String, dynamic>?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                yield content;
              }
            }
          } catch (_) {
            // 忽略单帧解析错误
          }
        }
      }
    } finally {
      client.close();
    }
  }

  /// 非流式一次性获取回复
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
  }) async {
    final buffer = StringBuffer();
    await for (final token in sendChatStream(
      history: history,
      newUserContent: newUserContent,
      sessionId: sessionId,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }
}
