import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../core/models/app_settings.dart';
import '../../core/models/chat_message.dart';
import '../../core/platform/location_bridge.dart';
import '../lightrag/lightrag_service.dart';
import 'web_search_service.dart';

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

class LlmService {
  final AppSettings settings;
  final WebSearchService _webSearchService;
  final LightRagService? _lightRagService;
  final http.Client? _injectedClient;

  static const int maxToolRounds = 3;

  static const Map<String, dynamic> webSearchToolDefinition = {
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

  static const Map<String, dynamic> lightRagToolDefinition = {
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

  /// 追加在系统提示词后的主人身份与 LightRAG 说明
  static const String lightRagPromptSuffix =
      '\n（身份说明：与你对话的人是你的主人浩哥。你可以调用 lightrag_query 工具查询主人的大量个人信息及历史对话记录，该工具只提供查询；对话内容会在切换到新会话后由系统自动保存，无需你操作。）';

  LlmService({
    required this.settings,
    WebSearchService? webSearchService,
    LightRagService? lightRagService,
    http.Client? client,
  })  : _webSearchService = webSearchService ?? WebSearchService(),
        _lightRagService = lightRagService ??
            (settings.enableLightRag &&
                    settings.lightRagBaseUrl.trim().isNotEmpty
                ? LightRagService(baseUrl: settings.lightRagBaseUrl)
                : null),
        _injectedClient = client;

  bool get _lightRagActive =>
      _lightRagService != null && settings.enableLightRag;

  /// 发送上下文至 OpenAI 兼容 API 并流式返回文本 token（支持可选图片多模态与 web_search 工具调用）
  Stream<String> sendChatStream({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
    void Function(String toolName, String query)? onToolCall,
  }) async* {
    final baseUrl = settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$baseUrl/chat/completions');

    final messages = <Map<String, dynamic>>[];

    // 1. 系统提示词 (用于控制大模型回答风格，并注入当前现实日期供搜索定位“今天/明天”)
    final now = DateTime.now();
    final currentDateStr =
        '${now.year}年${now.month.toString().padLeft(2, '0')}月${now.day.toString().padLeft(2, '0')}日';
    final baseSystemPrompt = settings.systemPrompt.trim() +
        (_lightRagActive ? lightRagPromptSuffix : '');
    // Android 自动定位，其余平台（或定位失败）使用设置中配置的地址
    final autoLocation = await LocationBridge.getCurrentAddress();
    final location = (autoLocation != null && autoLocation.isNotEmpty)
        ? autoLocation
        : settings.locationAddress.trim();
    final locationSuffix = location.isNotEmpty ? '\n（当前地理位置：$location）' : '';
    messages.add({
      'role': 'system',
      'content': baseSystemPrompt.isNotEmpty
          ? '$baseSystemPrompt\n（当前现实日期：$currentDateStr）$locationSuffix'
          : '当前现实日期：$currentDateStr$locationSuffix',
    });

    // 2. 携带当前 Session 内的完整上下文历史（历史轮次降级为纯文本，保持高效率与低延迟）
    for (final msg in history) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        messages.add(msg.toOpenAiMessage());
      }
    }

    // 3. 当前最新用户指令（若附带图片则构建 OpenAI 视觉标准 content 数组）
    if (imageBytes != null && imageBytes.isNotEmpty) {
      final base64Image = base64Encode(imageBytes);
      messages.add({
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': newUserContent,
          },
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/jpeg;base64,$base64Image',
            },
          },
        ],
      });
    } else {
      messages.add({
        'role': 'user',
        'content': newUserContent,
      });
    }

    final convId = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : (history.isNotEmpty && history.last.sessionId != null)
            ? history.last.sessionId!
            : 'conv-${DateTime.now().millisecondsSinceEpoch}';

    final client = _injectedClient ?? http.Client();
    bool toolsEnabledForRequest = settings.enableWebSearch || _lightRagActive;

    try {
      bool prefixResolved = false;
      final prefixBuffer = StringBuffer();
      final prefixPattern = RegExp(r'^\s*回你[：:,，\s]*');

      Stream<String> emitFilteredText(String chunk) async* {
        if (chunk.isEmpty) return;
        if (prefixResolved) {
          yield chunk;
        } else {
          prefixBuffer.write(chunk);
          final bufferedStr = prefixBuffer.toString();
          final ltrimmed = bufferedStr.trimLeft();
          if (ltrimmed == '回' || ltrimmed == '回你') {
            return;
          }
          final match = prefixPattern.firstMatch(bufferedStr);
          if (match != null && match.end > 0) {
            final remaining = bufferedStr.substring(match.end);
            prefixResolved = true;
            if (remaining.isNotEmpty) {
              yield remaining;
            }
          } else {
            prefixResolved = true;
            yield bufferedStr;
          }
        }
      }

      for (int round = 0; round <= maxToolRounds; round++) {
        final canOfferTools = toolsEnabledForRequest && round < maxToolRounds;
        final request = _buildChatRequest(
          url: url,
          messages: messages,
          convId: convId,
          includeTools: canOfferTools,
        );

        http.StreamedResponse streamedResponse = await client.send(request);

        if (streamedResponse.statusCode < 200 ||
            streamedResponse.statusCode >= 300) {
          final errorBody = await streamedResponse.stream.bytesToString();
          if (canOfferTools && _isToolsUnsupportedError(errorBody)) {
            // 若上游模型不支持 Function Calling，自动降级为无 tools 请求
            toolsEnabledForRequest = false;
            final fallbackRequest = _buildChatRequest(
              url: url,
              messages: messages,
              convId: convId,
              includeTools: false,
            );
            streamedResponse = await client.send(fallbackRequest);
            if (streamedResponse.statusCode < 200 ||
                streamedResponse.statusCode >= 300) {
              final fallbackErr = await streamedResponse.stream.bytesToString();
              throw Exception(
                  'LLM API Error ${streamedResponse.statusCode}: $fallbackErr');
            }
          } else if (errorBody.contains('11128') ||
              errorBody.contains('conversation id missing')) {
            // 遇到上游渠道抖动拦截，延迟 800ms 重试一次
            await Future.delayed(const Duration(milliseconds: 800));
            final freshConvId = 'wb-${DateTime.now().millisecondsSinceEpoch}';
            final retryRequest = _buildChatRequest(
              url: url,
              messages: messages,
              convId: freshConvId,
              includeTools: canOfferTools,
            );
            streamedResponse = await client.send(retryRequest);
            if (streamedResponse.statusCode < 200 ||
                streamedResponse.statusCode >= 300) {
              final secondErr = await streamedResponse.stream.bytesToString();
              throw Exception(
                  'LLM API Error ${streamedResponse.statusCode}: $secondErr');
            }
          } else {
            throw Exception(
                'LLM API Error ${streamedResponse.statusCode}: $errorBody');
          }
        }

        final lines = streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        final roundContentBuffer = StringBuffer();
        final roundReasoningBuffer = StringBuffer();
        final toolCallsByIndex = <int, AccumulatedToolCall>{};
        String streamHoldBuffer = '';
        bool inTextToolBlock = false;

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
                final choice0 = choices[0] as Map<String, dynamic>;
                final delta = (choice0['delta'] ?? choice0['message'])
                    as Map<String, dynamic>?;
                if (delta == null) continue;

                // 0. 记录 reasoning_content（DeepSeek 思考模式下多轮 tool_calls 必须回传该字段）
                final reasoning = delta['reasoning_content'] as String?;
                if (reasoning != null && reasoning.isNotEmpty) {
                  roundReasoningBuffer.write(reasoning);
                }

                // 1. 解析并累积标准 delta.tool_calls 分片
                final rawToolCalls = delta['tool_calls'] as List?;
                if (rawToolCalls != null) {
                  for (var i = 0; i < rawToolCalls.length; i++) {
                    final tc = rawToolCalls[i];
                    if (tc is! Map) continue;
                    final idx = (tc['index'] as num?)?.toInt() ?? i;
                    final tcId = tc['id']?.toString() ?? '';
                    final fn = tc['function'] as Map?;
                    final fnName = fn?['name']?.toString() ?? '';
                    final fnArgs = fn?['arguments']?.toString() ?? '';

                    final entry = toolCallsByIndex.putIfAbsent(
                      idx,
                      () => AccumulatedToolCall(
                        id: tcId.isNotEmpty ? tcId : 'call_${round}_$idx',
                        name: fnName,
                      ),
                    );
                    if (tcId.isNotEmpty) {
                      entry.id = tcId;
                    }
                    if (fnName.isNotEmpty) {
                      if (entry.name.isEmpty) {
                        entry.name = fnName;
                      } else if (entry.name != fnName &&
                          !entry.name.endsWith(fnName)) {
                        entry.name = '${entry.name}$fnName';
                      }
                    }
                    if (fnArgs.isNotEmpty) {
                      entry.argumentsBuffer.write(fnArgs);
                    }
                  }
                }

                // 2. 解析文本 content，自动拦截 <｜DSML｜ / <｜｜DSML｜｜ / <tool_call> 等文本工具标签
                final content = delta['content'] as String?;
                if (content != null && content.isNotEmpty) {
                  roundContentBuffer.write(content);
                  if (!inTextToolBlock) {
                    streamHoldBuffer += content;
                    final tagMatch = _textToolStartRegex
                        .firstMatch(streamHoldBuffer);
                    if (tagMatch != null) {
                      final safePrefix =
                          streamHoldBuffer.substring(0, tagMatch.start);
                      streamHoldBuffer = '';
                      inTextToolBlock = true;
                      if (safePrefix.isNotEmpty) {
                        yield* emitFilteredText(safePrefix);
                      }
                    } else {
                      final holdIdx =
                          _findPotentialToolTagSuffixIndex(streamHoldBuffer);
                      if (holdIdx == 0) {
                        // 整个缓冲可能是标签前缀（如 "<" 或 "<｜｜"），暂缓输出
                      } else if (holdIdx > 0) {
                        final safePart =
                            streamHoldBuffer.substring(0, holdIdx);
                        streamHoldBuffer = streamHoldBuffer.substring(holdIdx);
                        yield* emitFilteredText(safePart);
                      } else {
                        final toEmit = streamHoldBuffer;
                        streamHoldBuffer = '';
                        yield* emitFilteredText(toEmit);
                      }
                    }
                  }
                }
              }
            } catch (_) {
              // 忽略单帧解析错误
            }
          }
        }

        // 若单轮流结束且未进入文本工具标签块，把暂缓缓冲中的剩余普通字符输出
        if (!inTextToolBlock && streamHoldBuffer.isNotEmpty) {
          yield* emitFilteredText(streamHoldBuffer);
          streamHoldBuffer = '';
        }

        List<AccumulatedToolCall> accumulatedCalls = [];
        bool fromTextMarkup = false;

        if (toolCallsByIndex.isNotEmpty) {
          final sortedIndices = toolCallsByIndex.keys.toList()..sort();
          accumulatedCalls =
              sortedIndices.map((k) => toolCallsByIndex[k]!).toList();
        } else {
          final parsedTextCalls = parseTextToolCalls(
            roundContentBuffer.toString(),
            round: round,
          );
          if (parsedTextCalls.isNotEmpty) {
            accumulatedCalls = parsedTextCalls;
            fromTextMarkup = true;
          }
        }

        if (accumulatedCalls.isEmpty || round >= maxToolRounds) {
          break;
        }

        // 执行 web_search 工具调用（对相同 query 去重缓存，避免单轮重复请求两次相同搜索）
        final queryCache = <String, String>{};
        final toolOutputsForTextMode = <String>[];

        if (!fromTextMarkup) {
          final assistantMsg = <String, dynamic>{
            'role': 'assistant',
            'content': roundContentBuffer.isEmpty
                ? null
                : roundContentBuffer.toString(),
            'tool_calls':
                accumulatedCalls.map((tc) => tc.toOpenAiMap()).toList(),
          };
          if (roundReasoningBuffer.isNotEmpty) {
            assistantMsg['reasoning_content'] = roundReasoningBuffer.toString();
          }
          messages.add(assistantMsg);
        } else {
          final cleanBeforeTag = stripTextToolCalls(
            roundContentBuffer.toString(),
          );
          if (cleanBeforeTag.isNotEmpty) {
            messages.add({
              'role': 'assistant',
              'content': cleanBeforeTag,
            });
          }
        }

        for (final tc in accumulatedCalls) {
          final toolName = tc.name.isNotEmpty ? tc.name : 'web_search';
          final query = extractSearchQuery(tc.arguments);
          onToolCall?.call(toolName, query);

          String toolOutput;
          if (toolName == 'web_search') {
            if (queryCache.containsKey(query)) {
              toolOutput = queryCache[query]!;
            } else {
              toolOutput = await _webSearchService.searchAndFormat(query);
              queryCache[query] = toolOutput;
            }
          } else if (toolName == 'lightrag_query' && _lightRagActive) {
            final key = '$toolName:${tc.arguments}';
            if (queryCache.containsKey(key)) {
              toolOutput = queryCache[key]!;
            } else {
              toolOutput = await _lightRagService!.queryContext(
                query,
                mode: extractToolMode(tc.arguments),
              );
              queryCache[key] = toolOutput;
            }
          } else {
            toolOutput = 'Unsupported tool: $toolName';
          }

          if (!fromTextMarkup) {
            messages.add({
              'role': 'tool',
              'tool_call_id': tc.id,
              'name': toolName,
              'content': toolOutput,
            });
          } else {
            toolOutputsForTextMode.add(toolOutput);
          }
        }

        if (fromTextMarkup) {
          // 针对输出 DSML / <tool_call> 文本标签的网关渠道，不再下发 tools 定义，直接将搜索结果注入上下文请模型总结回答
          toolsEnabledForRequest = false;
          messages.add({
            'role': 'user',
            'content':
                '[系统已为您执行 web_search 联网搜索，最新结果如下]\n\n${toolOutputsForTextMode.join("\n\n")}\n\n请基于以上搜索结果，直接用自然、精炼的中文口语回答用户的提问，严禁再输出任何 DSML 或工具调用标签。',
          });
        }
      }

      if (!prefixResolved && prefixBuffer.isNotEmpty) {
        final bufferedStr = prefixBuffer.toString();
        final match = prefixPattern.firstMatch(bufferedStr);
        if (match != null && match.end > 0) {
          final remaining = bufferedStr.substring(match.end);
          if (remaining.isNotEmpty) {
            yield remaining;
          }
        } else {
          yield bufferedStr;
        }
      }
    } finally {
      if (_injectedClient == null) {
        client.close();
      }
    }
  }

  http.Request _buildChatRequest({
    required Uri url,
    required List<Map<String, dynamic>> messages,
    required String convId,
    required bool includeTools,
  }) {
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    if (settings.openAiApiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${settings.openAiApiKey}';
    }

    final requestBody = <String, dynamic>{
      'model':
          settings.openAiModel.isNotEmpty ? settings.openAiModel : 'gpt-4o-mini',
      'messages': messages,
      'stream': true,
      'temperature': 0.7,
      'conversation_id': convId,
      'user': convId,
    };

    if (includeTools) {
      requestBody['tools'] = [
        if (settings.enableWebSearch) webSearchToolDefinition,
        if (_lightRagActive) lightRagToolDefinition,
      ];
      requestBody['tool_choice'] = 'auto';
    }

    if (settings.disableThinking) {
      requestBody.addAll(getThinkingDisableParams(settings.openAiModel));
    }

    request.body = jsonEncode(requestBody);
    return request;
  }

  static final RegExp _textToolStartRegex = RegExp(
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
  static int _findPotentialToolTagSuffixIndex(String buffer) {
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
    final match = _textToolStartRegex.firstMatch(text);
    if (match != null) {
      return text.substring(0, match.start).trim();
    }
    return text.trim();
  }

  static bool _isToolsUnsupportedError(String errorBody) {
    final lower = errorBody.toLowerCase();
    return (lower.contains('tool') || lower.contains('function')) &&
        (lower.contains('not support') ||
            lower.contains('unsupported') ||
            lower.contains('unknown field') ||
            lower.contains('invalid parameter'));
  }

  /// 从工具调用的 arguments 字符串中提取查询关键词
  /// 用当前配置的（视觉）模型为图片生成简短中文描述，供归档到 LightRAG 使用；失败返回 null
  Future<String?> describeImage(Uint8List imageBytes) async {
    final baseUrl = settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = _injectedClient ?? http.Client();
    try {
      final body = <String, dynamic>{
        'model': settings.openAiModel.isNotEmpty
            ? settings.openAiModel
            : 'gpt-4o-mini',
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': '请用中文客观、详细地描述这张图片（场景、人物、物体、文字等），150 字以内，不要寒暄。',
              },
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
                },
              },
            ],
          },
        ],
        'stream': false,
        'temperature': 0.2,
      };
      if (settings.disableThinking) {
        body.addAll(getThinkingDisableParams(settings.openAiModel));
      }
      final resp = await client
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              if (settings.openAiApiKey.isNotEmpty)
                'Authorization': 'Bearer ${settings.openAiApiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      final content = decoded['choices']?[0]?['message']?['content'];
      return content is String ? content.trim() : null;
    } catch (_) {
      return null;
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  /// 从工具参数中提取 mode（默认 mix）
  static String extractToolMode(String rawArguments) {
    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map && decoded['mode'] is String) {
        return decoded['mode'] as String;
      }
    } catch (_) {}
    return 'mix';
  }

  static String extractSearchQuery(String rawArguments) {
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
      // 若 arguments 非合法完整 JSON，尝试用正则提取 "query": "..."
      final match =
          RegExp(r'"(?:query|q|keyword)"\s*:\s*"([^"]+)"').firstMatch(trimmed);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }
    return trimmed;
  }

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
    // 经各主流大模型官方 API 与网关（DeepSeek、Anthropic、Zhipu、Moonshot、Volcengine）验证支持
    return {
      'thinking': {
        'type': 'disabled',
      },
    };
  }

  /// 非流式一次性获取回复（支持可选图片多模态）
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  }) async {
    final buffer = StringBuffer();
    await for (final token in sendChatStream(
      history: history,
      newUserContent: newUserContent,
      sessionId: sessionId,
      imageBytes: imageBytes,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
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
