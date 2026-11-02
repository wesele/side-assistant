import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../core/models/app_settings.dart';
import '../../core/models/chat_message.dart';
import '../../core/platform/location_bridge.dart';
import '../../core/ports/knowledge_port.dart';
import '../../core/ports/llm_port.dart';
import '../../core/ports/llm_tool.dart';
import '../lightrag/lightrag_service.dart';
import 'support/llm_model_catalog_helper.dart';
import 'support/text_tool_call_parser.dart';
import 'tools/capture_photo_tool.dart';
import 'tools/lightrag_tool.dart';
import 'tools/web_search_tool.dart';
import 'web_search_service.dart';

export 'support/text_tool_call_parser.dart'
    show AccumulatedToolCall, TextToolCallParser;

class LlmService implements LlmPort {
  AppSettings settings;
  final LlmToolRegistry toolRegistry;
  final http.Client? _injectedClient;

  /// 局部热重载：更新 LLM 与知识库配置，不影响其它领域服务
  @override
  void applyConfig(LlmConfig config) {
    settings.llm = config;
  }

  static const int maxToolRounds = 3;

  /// 保留静态工具 Schema 定义的 Getter 访问器，保障向后兼容
  static Map<String, dynamic> get webSearchToolDefinition =>
      WebSearchTool.toolDefinition;

  static Map<String, dynamic> get lightRagToolDefinition =>
      LightRagTool.toolDefinition;

  static Map<String, dynamic> get capturePhotoToolDefinition =>
      CapturePhotoTool.toolDefinition;

  /// 构建统一的语音对话意图与回复系统提示词
  static String buildDialogueIntentSystemPrompt({
    required AppSettings settings,
    required bool isInContinuousMode,
  }) {
    final assistantName = settings.startWords.isNotEmpty
        ? settings.startWords.first
        : (settings.startWord.isNotEmpty ? settings.startWord : '小曼');
    final aliasNames = settings.startWords.isNotEmpty
        ? settings.startWords.join('、')
        : assistantName;
    final exitWords = settings.exitContinuousWords.isNotEmpty
        ? settings.exitContinuousWords.join('、')
        : '结束对话、再见、退下';
    final resetWords = settings.resetWords.isNotEmpty
        ? settings.resetWords.join('、')
        : '新起一个、换个话题、重新开始';

    final stateStr = isInContinuousMode ? '【连续对话模式】' : '【待机模式】';

    return '''
你是一个幽默、体贴、言简意赅的随身语音管家，你的名字是【$assistantName】（主人可能称呼你为：$aliasNames）。
当前系统处于$stateStr。
你的任务是：根据主人输入的语音识别内容，首先判断主人的意图，并给出相应的处理及口语化回复。

【意图与状态判定规则】：
1. 若处于【待机模式】：
   - 主人是否有要求与你开始对话的意图？典型的特征是：呼唤你的名字（$aliasNames），或者直接向你提问/下达指令。
   - 如果主人确实在呼叫你或向你提问：intent 为 "start_or_continue"，should_reply 为 true，并在 reply 字段中直接给出回答。
   - 如果主人是在与他人交谈、自言自语、背景旁白等，并非在跟你对话：intent 为 "ignore"，should_reply 为 false，reply 为空字符串。

2. 若处于【连续对话模式】：
   - 主人是否在继续向你询问或交流？如果是：intent 为 "start_or_continue"，should_reply 为 true，在 reply 中回答。
   - 主人是否要求新起话题、重置会话？（如说“$resetWords”等）：intent 为 "new_session"，should_reply 为 true，并在 reply 中礼貌确认开始新话题。
   - 主人是否要求退出对话、退下？（如说“$exitWords”等）：intent 为 "exit"，should_reply 为 true，并在 reply 中简短礼貌告别。
   - 主人是否在连续对话中转头与身边其他人讲话或接电话？如果是：intent 为 "ignore"，should_reply 为 false，reply 为空字符串。

【视觉拍照能力与铁律约束】：
1. 拍照触发条件：当且仅当主人在【当前最新一条指令】中明确要求你“拍张照”、“拍一下”、“拍照看看”、“识别面前的物体/文字”或需要观察新的现场画面时，才允许调用 capture_photo 工具。
2. 严禁连续或无故拍照（绝对铁律）：
   - 如果主人只是就上一轮已经拍摄的照片或刚才讨论过的内容进行追问（例如询问刚才物体的养护技巧、名称含义、价格、对比、建议等），你必须直接根据已有对话历史进行回答，【严禁再次调用 capture_photo】！
   - 如果主人的话语中没有要求拍摄新照片或没有要求看新东西，即使出现“看一下”、“帮我看看这个情况”等代词或泛指词，也应优先结合对话历史理解，绝对不要触发拍照。

【输出格式铁律】：
无论任何情况，你必须且只能输出严格的单层 JSON 对象，严禁输出任何 Markdown 标记或多余解释：
{
  "intent": "start_or_continue" | "new_session" | "exit" | "ignore",
  "should_reply": true | false,
  "reply": "助手口语化回答内容（适合语音朗读，直接说内容，严禁以“回你：”等前缀开头）"
}
''';
  }

  /// 追加在系统提示词后的主人身份与 LightRAG 说明
  static const String lightRagPromptSuffix =
      '\n（身份说明：与你对话的人是你的主人浩哥。你可以调用 lightrag_query 工具查询主人的大量个人信息及历史对话记录，该工具只提供查询；对话内容会在切换到新会话后由系统自动保存，无需你操作。）';

  LlmService({
    required this.settings,
    LlmToolRegistry? toolRegistry,
    WebSearchService? webSearchService,
    KnowledgePort? lightRagService,
    http.Client? client,
  })  : toolRegistry = toolRegistry ??
            _createDefaultToolRegistry(
              settings: settings,
              webSearchService: webSearchService,
              lightRagService: lightRagService,
            ),
        _injectedClient = client;

  static LlmToolRegistry _createDefaultToolRegistry({
    required AppSettings settings,
    WebSearchService? webSearchService,
    KnowledgePort? lightRagService,
  }) {
    final registry = LlmToolRegistry();
    registry.register(WebSearchTool(searchService: webSearchService));
    registry.register(LightRagTool(
      knowledgePort: lightRagService ??
          (settings.enableLightRag && settings.lightRagBaseUrl.trim().isNotEmpty
              ? LightRagService(baseUrl: settings.lightRagBaseUrl)
              : null),
    ));
    registry.register(const CapturePhotoTool());
    return registry;
  }

  bool get _lightRagActive =>
      toolRegistry.isToolEnabled('lightrag_query', settings);

  /// 发送上下文至 OpenAI 兼容 API 并流式返回文本 token（支持可选图片多模态与 web_search 工具调用）
  @override
  Stream<String> sendChatStream({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  }) async* {
    final baseUrl =
        settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$baseUrl/chat/completions');

    final messages = <Map<String, dynamic>>[];

    // 1. 系统提示词 (用于控制大模型回答风格，并注入当前现实日期供搜索定位“今天/明天”)
    final now = DateTime.now();
    final currentDateStr =
        '${now.year}年${now.month.toString().padLeft(2, '0')}月${now.day.toString().padLeft(2, '0')}日';
    final baseSystemPrompt = isDialogueIntentMode
        ? buildDialogueIntentSystemPrompt(
            settings: settings,
            isInContinuousMode: isInContinuousMode,
          )
        : (settings.systemPrompt.trim() +
            (_lightRagActive ? lightRagPromptSuffix : ''));
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
        if (msg.role == 'user' &&
            msg.imagePath != null &&
            msg.imagePath!.isNotEmpty) {
          messages.add({
            'role': 'user',
            'content':
                '${msg.content}\n（系统记录：本轮已调用相机拍摄现场照片并由你查看完成，后续非拍照追问请直接基于已知结论回答）',
          });
        } else {
          messages.add(msg.toOpenAiMessage());
        }
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
    final baseToolContext = LlmToolContext(
      onCapturePhoto: onCapturePhoto,
      sessionId: sessionId,
    );
    bool toolsEnabledForRequest = toolRegistry
        .getEnabledDefinitions(settings, context: baseToolContext)
        .isNotEmpty;

    try {
      bool prefixResolved = false;
      final prefixBuffer = StringBuffer();
      final prefixPattern = RegExp(r'^\s*回你[：:,，\s]*');

      Stream<String> emitFilteredText(String chunk) async* {
        if (chunk.isEmpty) return;
        if (isDialogueIntentMode || prefixResolved) {
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
          toolContext: baseToolContext,
          allowCapturePhoto: onCapturePhoto != null,
        );

        http.StreamedResponse streamedResponse = await client.send(request);

        if (streamedResponse.statusCode < 200 ||
            streamedResponse.statusCode >= 300) {
          final errorBody = await streamedResponse.stream.bytesToString();
          if (canOfferTools &&
              TextToolCallParser.isToolsUnsupportedError(errorBody)) {
            // 若上游模型不支持 Function Calling，自动降级为无 tools 请求
            toolsEnabledForRequest = false;
            final fallbackRequest = _buildChatRequest(
              url: url,
              messages: messages,
              convId: convId,
              includeTools: false,
              toolContext: baseToolContext,
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
              toolContext: baseToolContext,
              allowCapturePhoto: onCapturePhoto != null,
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
                    final tagMatch = TextToolCallParser.textToolStartRegex
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
                          TextToolCallParser.findPotentialToolTagSuffixIndex(
                              streamHoldBuffer);
                      if (holdIdx == 0) {
                        // 整个缓冲可能是标签前缀（如 "<" 或 "<｜｜"），暂缓输出
                      } else if (holdIdx > 0) {
                        final safePart = streamHoldBuffer.substring(0, holdIdx);
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
          final query = WebSearchTool.extractQuery(tc.arguments);
          onToolCall?.call(toolName, query);

          Uint8List? roundCapturedPhoto;
          final invocationContext = baseToolContext.copyWith(
            onPhotoCaptured: (bytes) => roundCapturedPhoto = bytes,
          );

          String toolOutput;
          final cacheKey =
              '$toolName:${query.isNotEmpty ? query : tc.arguments}';
          if (queryCache.containsKey(cacheKey)) {
            toolOutput = queryCache[cacheKey]!;
          } else {
            toolOutput = await toolRegistry.execute(
              toolName,
              tc.arguments,
              context: invocationContext,
            );
            if (roundCapturedPhoto == null) {
              queryCache[cacheKey] = toolOutput;
            }
          }

          if (!fromTextMarkup) {
            messages.add({
              'role': 'tool',
              'tool_call_id': tc.id,
              'name': toolName,
              'content': toolOutput,
            });
            if (roundCapturedPhoto != null && roundCapturedPhoto!.isNotEmpty) {
              final b64 = base64Encode(roundCapturedPhoto!);
              messages.add({
                'role': 'user',
                'content': [
                  {
                    'type': 'text',
                    'text': '（系统提示：已使用摄像头完成拍摄，以下是拍摄到的现场画面）',
                  },
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/jpeg;base64,$b64'},
                  },
                ],
              });
            }
          } else {
            toolOutputsForTextMode.add(toolOutput);
          }
        }

        if (fromTextMarkup) {
          // 针对输出 DSML / <tool_call> 文本标签的网关渠道，不再下发 tools 定义，直接将搜索结果注入上下文请模型总结回答
          toolsEnabledForRequest = false;
          final executedTool = accumulatedCalls.isNotEmpty &&
                  accumulatedCalls.first.name.isNotEmpty
              ? accumulatedCalls.first.name
              : 'web_search';
          final hint = executedTool == 'web_search'
              ? 'web_search 联网搜索'
              : '$executedTool 检索';
          messages.add({
            'role': 'user',
            'content':
                '[系统已为您执行 $hint，最新结果如下]\n\n${toolOutputsForTextMode.join("\n\n")}\n\n请基于以上搜索结果，直接用自然、精炼的中文口语回答用户的提问，严禁再输出任何 DSML 或工具调用标签。',
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
    LlmToolContext? toolContext,
    bool allowCapturePhoto = false,
  }) {
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    if (settings.openAiApiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${settings.openAiApiKey}';
    }

    final requestBody = <String, dynamic>{
      'model': settings.openAiModel.isNotEmpty
          ? settings.openAiModel
          : 'gpt-4o-mini',
      'messages': messages,
      'stream': true,
      'temperature': 0.7,
      'conversation_id': convId,
      'user': convId,
    };

    if (includeTools) {
      final effectiveContext = toolContext ??
          LlmToolContext(
            onCapturePhoto: allowCapturePhoto ? () async => null : null,
          );
      final tools = toolRegistry.getEnabledDefinitions(
        settings,
        context: effectiveContext,
      );
      if (tools.isNotEmpty) {
        requestBody['tools'] = tools;
        requestBody['tool_choice'] = 'auto';
      }
    }

    if (settings.disableThinking) {
      requestBody.addAll(getThinkingDisableParams(settings.openAiModel));
    }

    request.body = jsonEncode(requestBody);
    return request;
  }

  /// 从模型输出的 DSML 或 `<tool_call>` 文本标签中提取工具调用列表
  static List<AccumulatedToolCall> parseTextToolCalls(
    String text, {
    int round = 0,
  }) =>
      TextToolCallParser.parseTextToolCalls(text, round: round);

  /// 剥离文本中的 DSML 或 `<tool_call>` 标签块，只保留标签之前的正常文本
  static String stripTextToolCalls(String text) =>
      TextToolCallParser.stripTextToolCalls(text);

  /// 从工具调用的 arguments 字符串中提取查询关键词
  /// 用当前配置的（视觉）模型为图片生成简短中文描述，供归档到 LightRAG 使用；失败返回 null
  @override
  Future<String?> describeImage(Uint8List imageBytes) async {
    final baseUrl =
        settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
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
  static String extractToolMode(String rawArguments) =>
      LightRagTool.extractMode(rawArguments);

  /// 从工具调用的 arguments 字符串中提取查询关键词
  static String extractSearchQuery(String rawArguments) =>
      WebSearchTool.extractQuery(rawArguments);

  /// 根据模型名称自动推断关闭思考所适用的 API 请求参数
  static Map<String, dynamic> getThinkingDisableParams(String modelName) =>
      LlmModelCatalogHelper.getThinkingDisableParams(modelName);

  /// 非流式一次性获取回复（支持可选图片多模态）
  @override
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
  }) =>
      LlmModelCatalogHelper.fetchAvailableModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
        client: client,
      );
}
