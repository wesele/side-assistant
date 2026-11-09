import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/services/llm/llm_service.dart';

class _MockHttpStreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  _MockHttpStreamClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('大模型意图裁决与连续对话状态机测试', () {
    late AppSettings settings;

    setUp(() {
      settings = AppSettings(
        openAiBaseUrl: 'https://api.openai.com/v1',
        openAiApiKey: 'fake-key',
        openAiModel: 'gpt-4o-mini',
        startWord: '小曼',
        silenceTimeoutSeconds: 1, // 加速测试
        enablePromptTone: true,
        enableTtsPlayback: false,
        enableWebSearch: false,
        enableLightRag: false,
      );
    });

    test('待机状态下收到语音，大模型判定为对话请求：成功唤醒、进入连续对话并生成消息', () async {
      final fakeResponses = [
        '{\n',
        '  "intent": "start_or_continue",\n',
        '  "should_reply": true,\n',
        '  "reply": "我在呢，今天天气晴朗。"\n',
        '}',
      ];

      final mockClient = _MockHttpStreamClient((req) async {
        final stream = Stream.fromIterable(
          fakeResponses.map(
            (token) => utf8.encode('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': token}
                    }
                  ]
                })}\n\n'),
          ),
        );
        return http.StreamedResponse(stream, 200);
      });

      final controller = AssistantController(
        settings: settings,
        llmService: LlmService(settings: settings, client: mockClient),
      );

      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.isInContinuousMode, isFalse);
      expect(controller.messages, isEmpty);

      // 模拟麦克风识别到语音
      await controller.processRecognizedText('小曼今天天气怎么样');

      // 处于倾听中
      expect(controller.status, equals(AssistantStatus.listeningContent));

      // 等待静音超时触发自动提交及大模型完成
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (controller.isInContinuousMode && controller.messages.length == 2) {
          break;
        }
      }

      // 验证成功进入连续对话模式
      expect(controller.isInContinuousMode, isTrue);
      expect(controller.messages.length, equals(2));
      expect(controller.messages[0].role, equals('user'));
      expect(controller.messages[0].content, equals('小曼今天天气怎么样'));
      expect(controller.messages[1].role, equals('assistant'));
      expect(controller.messages[1].content, equals('我在呢，今天天气晴朗。'));
    });

    test('待机状态下收到无关旁白，大模型判定不予回复：保持待机并将该语音记录为背景信息', () async {
      final fakeResponses = [
        '{"intent": "ignore", "should_reply": false, "reply": ""}',
      ];

      final mockClient = _MockHttpStreamClient((req) async {
        final stream = Stream.fromIterable(
          fakeResponses.map(
            (token) => utf8.encode('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': token}
                    }
                  ]
                })}\n\n'),
          ),
        );
        return http.StreamedResponse(stream, 200);
      });

      final disabledSettings = AppSettings(
        openAiBaseUrl: 'https://api.openai.com/v1',
        openAiApiKey: 'fake-key',
        openAiModel: 'gpt-4o-mini',
        startWord: '小曼',
        startWordMode: AppConstants.startWordModeDisabled,
        silenceTimeoutSeconds: 1,
        enablePromptTone: true,
        enableTtsPlayback: false,
        enableWebSearch: false,
        enableLightRag: false,
      );

      final controller = AssistantController(
        settings: disabledSettings,
        llmService: LlmService(settings: disabledSettings, client: mockClient),
      );

      // 模拟环境自言自语
      await controller.processRecognizedText('今天中午吃什么外卖呢');
      expect(controller.status, equals(AssistantStatus.listeningContent));

      // 等待静音超时提交大模型并退回待机
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (controller.status == AssistantStatus.idle &&
            controller.statusHint.contains('未检测到对话意图')) {
          break;
        }
      }

      // 验证未进入连续对话，但语音被沉淀为无交谈意图的背景历史消息
      expect(controller.isInContinuousMode, isFalse);
      expect(controller.messages.length, equals(1));
      expect(controller.messages[0].role, equals('user'));
      expect(controller.messages[0].content, equals('今天中午吃什么外卖呢'));
      expect(controller.messages[0].isUnintended, isTrue);
      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.statusHint, contains('未检测到对话意图'));
    });

    test('连续对话模式下，收到“换个话题”，大模型判定为 new_session：成功重置新会话', () async {
      final fakeResponses = [
        '{\n"intent": "new_session",\n"should_reply": true,\n"reply": "好的，新话题开启！"\n}',
      ];

      final mockClient = _MockHttpStreamClient((req) async {
        final stream = Stream.fromIterable(
          fakeResponses.map(
            (token) => utf8.encode('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': token}
                    }
                  ]
                })}\n\n'),
          ),
        );
        return http.StreamedResponse(stream, 200);
      });

      final controller = AssistantController(
        settings: settings,
        llmService: LlmService(settings: settings, client: mockClient),
      );
      controller.enterContinuousModeForTesting();

      final initialSessionId = controller.currentSessionId;

      // 模拟用户要求新起一个话题
      await controller.processRecognizedText('换个新话题聊聊电影吧');
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (controller.messages.length == 2) {
          break;
        }
      }

      // 验证 SessionId 已刷新，且保留在连续对话中
      expect(controller.currentSessionId, isNot(equals(initialSessionId)));
      expect(controller.isInContinuousMode, isTrue);
      expect(controller.messages.length, equals(2));
      expect(controller.messages.last.content, equals('好的，新话题开启！'));
    });

    test('连续对话模式下，收到告别语，大模型判定为 exit：成功退出连续对话', () async {
      final fakeResponses = [
        '{"intent": "exit", "should_reply": true, "reply": "好的，随时呼唤我。"}',
      ];

      final mockClient = _MockHttpStreamClient((req) async {
        final stream = Stream.fromIterable(
          fakeResponses.map(
            (token) => utf8.encode('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': token}
                    }
                  ]
                })}\n\n'),
          ),
        );
        return http.StreamedResponse(stream, 200);
      });

      final controller = AssistantController(
        settings: settings,
        llmService: LlmService(settings: settings, client: mockClient),
      );
      controller.enterContinuousModeForTesting();

      // 发送告别
      await controller.processRecognizedText('没事了你先退下吧');
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (controller.status == AssistantStatus.idle) {
          break;
        }
      }

      // 验证退出连续对话
      expect(controller.isInContinuousMode, isFalse);
    });

    test('播报期间开口说话立即打断 TTS 并进入倾听', () async {
      final controller = AssistantController(
        settings: settings,
      );

      // 手动将状态置为播放态
      controller.setStatusForTesting(
        AssistantStatus.playing,
        '正在朗读长篇回复...',
      );
      expect(controller.status, equals(AssistantStatus.playing));

      // 用户开口说话
      await controller.processRecognizedText('等等我有新问题');

      // 验证已立即打断并进入倾听态
      expect(controller.status, equals(AssistantStatus.listeningContent));
      expect(controller.liveTranscript, equals('等等我有新问题'));
    });

    test('大模型发起 capture_photo 工具调用，拍照后附带图像二次请求并输出回复', () async {
      int requestCount = 0;
      String? secondRequestBody;

      final mockClient = _MockHttpStreamClient((req) async {
        requestCount++;
        if (requestCount == 1) {
          // 第一轮请求：LLM 判断需要拍照，返回 capture_photo 工具调用
          final toolCallData = utf8.encode('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_snap_123',
                          'type': 'function',
                          'function': {
                            'name': 'capture_photo',
                            'arguments': '{"reason": "看主人手里的物品"}',
                          },
                        }
                      ]
                    }
                  }
                ]
              })}\n\n');
          return http.StreamedResponse(Stream.value(toolCallData), 200);
        } else {
          // 第二轮请求：捕获请求内容（包含照片），返回最终意图与回复
          final bodyBytes = (req as http.Request).body;
          secondRequestBody = bodyBytes;

          final fakeResponses = [
            '{"intent": "start_or_continue", "should_reply": true, "reply": "你手里拿的是一只苹果。"}',
          ];
          final stream = Stream.fromIterable(
            fakeResponses.map(
              (token) => utf8.encode('data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': token}
                      }
                    ]
                  })}\n\n'),
            ),
          );
          return http.StreamedResponse(stream, 200);
        }
      });

      final controller = AssistantController(
        settings: settings,
        llmService: LlmService(settings: settings, client: mockClient),
      );

      // 用户询问面前的物品
      await controller.processRecognizedText('小曼 帮我看看我手里拿的是什么');

      // 等待执行工具调用与第二轮回复完成
      for (int i = 0; i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (controller.messages.length == 2 &&
            controller.messages.last.role == 'assistant') {
          break;
        }
      }

      expect(requestCount, equals(2));
      expect(secondRequestBody, isNotNull);
      expect(secondRequestBody!.contains('data:image/jpeg;base64,'), isTrue);
      expect(secondRequestBody!.contains('call_snap_123'), isTrue);
      expect(controller.messages.last.content, equals('你手里拿的是一只苹果。'));
      expect(controller.messages.first.imagePath, isNotNull);
    });

    test('record_background_speech 工具调用短路机制与 ignore 意图快速返回', () async {
      int requestCount = 0;
      final mockClient = _MockHttpStreamClient((req) async {
        requestCount++;
        final toolCallData = utf8.encode('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {
                    'content': null,
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_bg_1',
                        'type': 'function',
                        'function': {
                          'name': 'record_background_speech',
                          'arguments': jsonEncode({
                            'text': '今天天气不错，去散个步',
                            'reason': '主人在打电话',
                          }),
                        }
                      }
                    ]
                  }
                }
              ]
            })}\n\n');
        return http.StreamedResponse(Stream.value(toolCallData), 200);
      });

      final llmService = LlmService(settings: settings, client: mockClient);
      final stream = llmService.sendChatStream(
        history: [],
        newUserContent: '今天天气不错，去散个步',
        isDialogueIntentMode: true,
      );

      final tokens = await stream.toList();
      expect(requestCount, equals(1));
      expect(tokens.length, equals(1));
      expect(
        tokens.first,
        equals('{"intent": "ignore", "should_reply": false, "reply": ""}'),
      );
    });

    test('ChatMessage.toOpenAiMessage() 背景消息前缀格式化与 copyWith/序列化契约', () {
      final normalMsg = ChatMessage(
        id: 'msg_normal',
        role: 'user',
        content: '你好呀',
        timestamp: DateTime(2026, 1, 1),
        isUnintended: false,
      );
      expect(normalMsg.toOpenAiMessage(), {
        'role': 'user',
        'content': '你好呀',
      });

      final unintendedMsg = normalMsg.copyWith(isUnintended: true);
      expect(unintendedMsg.isUnintended, isTrue);
      expect(unintendedMsg.toOpenAiMessage(), {
        'role': 'user',
        'content': '[背景信息（无交谈意图）] 你好呀',
      });

      final map = unintendedMsg.toMap();
      expect(map['isUnintended'], isTrue);

      final restored = ChatMessage.fromMap(map);
      expect(restored.isUnintended, isTrue);
      expect(restored.content, equals('你好呀'));
      expect(
          restored.toOpenAiMessage()['content'], equals('[背景信息（无交谈意图）] 你好呀'));
    });
  });
}
