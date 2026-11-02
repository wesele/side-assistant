import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/llm/web_search_service.dart';

class _FakeStreamedClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.Request request) _handler;

  _FakeStreamedClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _handler(request as http.Request);
  }
}

http.StreamedResponse _sseResponse(List<Map<String, dynamic>> frames) {
  final lines = <String>[
    for (final f in frames) 'data: ${jsonEncode(f)}\n\n',
    'data: [DONE]\n\n',
  ];
  final stream = Stream<List<int>>.fromIterable(
    lines.map((s) => utf8.encode(s)),
  );
  return http.StreamedResponse(stream, 200);
}

void main() {
  group('1. AppSettings enableWebSearch 配置项测试', () {
    test('默认开启 enableWebSearch 且支持序列化/反序列化', () {
      final settings = AppSettings();
      expect(settings.enableWebSearch,
          equals(AppConstants.defaultEnableWebSearch));
      expect(settings.enableWebSearch, isTrue);

      final disabled = AppSettings(enableWebSearch: false);
      final map = disabled.toMap();
      expect(map['enableWebSearch'], isFalse);

      final restored = AppSettings.fromMap(map);
      expect(restored.enableWebSearch, isFalse);

      final defaultRestored = AppSettings.fromMap({});
      expect(defaultRestored.enableWebSearch, isTrue);
    });
  });

  group('2. WebSearchService 解析与回退测试', () {
    test('parseBingHtml 正确提取标题、链接与摘要', () {
      const sampleHtml = '''
      <ol id="b_results">
        <li class="b_algo">
          <h2><a href="https://example.com/news1">今日<strong>科技</strong>新闻 &amp; 动态</a></h2>
          <div class="b_caption"><p>这是第一条搜索结果的摘要内容。</p></div>
        </li>
        <li class="b_algo">
          <h2><a href="https://example.com/news2">第二条结果</a></h2>
          <p>这是第二条摘要。</p>
        </li>
      </ol>
      ''';
      final results = WebSearchService.parseBingHtml(sampleHtml);
      expect(results.length, 2);
      expect(results[0].title, '今日 科技 新闻 & 动态');
      expect(results[0].url, 'https://example.com/news1');
      expect(results[0].snippet, '这是第一条搜索结果的摘要内容。');
      expect(results[1].title, '第二条结果');
      expect(results[1].url, 'https://example.com/news2');
      expect(results[1].snippet, '这是第二条摘要。');
    });

    test('parseDuckDuckGoHtml 正确提取并解码 uddg 重定向链接', () {
      const sampleDdgHtml = '''
      <div class="result">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdart.dev%2Fguides">Dart Programming</a>
        <a class="result__snippet">Dart is a client-optimized language.</a>
      </div>
      ''';
      final results = WebSearchService.parseDuckDuckGoHtml(sampleDdgHtml);
      expect(results.length, 1);
      expect(results[0].title, 'Dart Programming');
      expect(results[0].url, 'https://dart.dev/guides');
      expect(results[0].snippet, 'Dart is a client-optimized language.');
    });

    test('Bing 失败时自动回退至 DuckDuckGo 并格式化输出', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host.contains('bing.com')) {
          return http.Response('Server Error', 500);
        }
        return http.Response.bytes(
          utf8.encode('''
          <div class="result">
            <a class="result__a" href="https://flutter.dev">Flutter Official</a>
            <a class="result__snippet">Build apps for any screen.</a>
          </div>
          '''),
          200,
        );
      });

      final service = WebSearchService(client: mockClient);
      final formatted = await service.searchAndFormat('Flutter');
      expect(formatted, contains('Web search results for "Flutter":'));
      expect(formatted, contains('[1] Flutter Official'));
      expect(formatted, contains('URL: https://flutter.dev'));
      expect(formatted, contains('Snippet: Build apps for any screen.'));
    });
  });

  group('3. LlmService web_search Tool Calling 循环测试', () {
    test('流式接收分片 tool_calls -> 执行 web_search -> 回传结果并流式输出最终回答', () async {
      final capturedRequests = <Map<String, dynamic>>[];
      final triggeredTools = <(String, String)>[];

      final fakeSearchClient = MockClient((req) async {
        return http.Response.bytes(
          utf8.encode('''
          <ol id="b_results">
            <li class="b_algo">
              <h2><a href="https://weather.example.com">北京今日天气</a></h2>
              <p>晴转多云，最高气温 24°C。</p>
            </li>
          </ol>
          '''),
          200,
        );
      });

      var callCount = 0;
      final fakeLlmClient = _FakeStreamedClient((request) async {
        callCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        capturedRequests.add(body);

        if (callCount == 1) {
          // 第一轮：大模型决定调用 web_search，且 arguments 分两帧流式到达
          return _sseResponse([
            {
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_weather_1',
                        'type': 'function',
                        'function': {
                          'name': 'web_search',
                          'arguments': '{"que',
                        },
                      }
                    ],
                  },
                }
              ],
            },
            {
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'function': {
                          'arguments': 'ry": "北京今天天气"}',
                        },
                      }
                    ],
                  },
                }
              ],
            },
          ]);
        } else {
          // 第二轮：大模型收到 tool 搜索结果后给出最终语音回复（同时测试过滤“回你：”前缀）
          return _sseResponse([
            {
              'choices': [
                {
                  'delta': {'content': '回你：北京今天'},
                }
              ],
            },
            {
              'choices': [
                {
                  'delta': {'content': '晴转多云，最高24度。'},
                }
              ],
            },
          ]);
        }
      });

      final llmService = LlmService(
        settings: AppSettings(enableWebSearch: true),
        webSearchService: WebSearchService(client: fakeSearchClient),
        client: fakeLlmClient,
      );

      final tokens = <String>[];
      await for (final token in llmService.sendChatStream(
        history: [],
        newUserContent: '北京今天天气怎么样',
        onToolCall: (name, query) => triggeredTools.add((name, query)),
      )) {
        tokens.add(token);
      }

      expect(tokens.join(), equals('北京今天晴转多云，最高24度。'));
      expect(triggeredTools, equals([('web_search', '北京今天天气')]));
      expect(capturedRequests.length, 2);

      // 验证第一轮请求携带了 web_search tool 定义
      expect(capturedRequests[0]['tools'], isNotNull);
      final tools = capturedRequests[0]['tools'] as List;
      expect(tools.first['function']['name'], equals('web_search'));

      // 验证第二轮请求包含 assistant(tool_calls) 与 tool(search result) 消息
      final secondMessages = capturedRequests[1]['messages'] as List;
      final assistantToolMsg = secondMessages.firstWhere(
        (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
      );
      expect(
        assistantToolMsg['tool_calls'][0]['id'],
        equals('call_weather_1'),
      );
      final toolResultMsg = secondMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolResultMsg['tool_call_id'], equals('call_weather_1'));
      expect(toolResultMsg['content'], contains('晴转多云，最高气温 24°C'));
    });

    test('当 enableWebSearch 关闭时请求体不携带 tools', () async {
      Map<String, dynamic>? capturedBody;
      final fakeLlmClient = _FakeStreamedClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _sseResponse([
          {
            'choices': [
              {
                'delta': {'content': '直接回答'},
              }
            ],
          },
        ]);
      });

      final llmService = LlmService(
        settings: AppSettings(enableWebSearch: false, enableLightRag: false),
        client: fakeLlmClient,
      );

      final reply = await llmService.sendChat(
        history: [],
        newUserContent: '你好',
      );
      expect(reply, equals('直接回答'));
      expect(capturedBody?.containsKey('tools'), isFalse);
    });

    test('上游模型不支持 tools 返回 400 时自动降级重试无 tools 请求', () async {
      final capturedBodies = <Map<String, dynamic>>[];
      final fakeLlmClient = _FakeStreamedClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        capturedBodies.add(body);
        if (body.containsKey('tools')) {
          return http.StreamedResponse(
            Stream.value(utf8
                .encode('{"error": "tools is not supported by this model"}')),
            400,
          );
        }
        return _sseResponse([
          {
            'choices': [
              {
                'delta': {'content': '降级成功回复'},
              }
            ],
          },
        ]);
      });

      final llmService = LlmService(
        settings: AppSettings(enableWebSearch: true),
        client: fakeLlmClient,
      );

      final reply = await llmService.sendChat(
        history: [],
        newUserContent: '测试降级',
      );
      expect(reply, equals('降级成功回复'));
      expect(capturedBodies.length, 2);
      expect(capturedBodies[0].containsKey('tools'), isTrue);
      expect(capturedBodies[1].containsKey('tools'), isFalse);
    });

    test('流式接收 DeepSeek DSML 文本工具标签时自动拦截不外泄，并执行搜索完成第二轮回答', () async {
      final triggeredTools = <(String, String)>[];
      final fakeSearchClient = MockClient((req) async {
        return http.Response.bytes(
          utf8.encode('''
          <ol id="b_results">
            <li class="b_algo">
              <h2><a href="https://weather.example.com">马德里天气</a></h2>
              <p>马德里明天多云，气温 5°C 到 19°C，降水概率 0%。</p>
            </li>
          </ol>
          '''),
          200,
        );
      });

      var callCount = 0;
      final fakeLlmClient = _FakeStreamedClient((request) async {
        callCount++;
        if (callCount == 1) {
          // 模拟手机上真实复现的 DSML 文本流式分片输出
          return _sseResponse([
            {
              'choices': [
                {
                  'delta': {'content': '<｜｜DS'},
                }
              ],
            },
            {
              'choices': [
                {
                  'delta': {
                    'content':
                        'ML｜｜ calls>\n<｜｜DSML｜｜ invoke name="web_search">\n<｜｜DSML｜｜ parameter name="query" string="true">马德里 明天 天气</｜｜DSML｜｜ parameter>\n</｜｜DSML｜｜ invoke>\n</｜｜DSML｜｜ calls>',
                  },
                }
              ],
            },
          ]);
        } else {
          return _sseResponse([
            {
              'choices': [
                {
                  'delta': {'content': '马德里明天多云，5到19度，不用带伞。'},
                }
              ],
            },
          ]);
        }
      });

      final llmService = LlmService(
        settings: AppSettings(enableWebSearch: true),
        webSearchService: WebSearchService(client: fakeSearchClient),
        client: fakeLlmClient,
      );

      final tokens = <String>[];
      await for (final token in llmService.sendChatStream(
        history: [],
        newUserContent: '你查查马德里明天天气怎么样',
        onToolCall: (name, query) => triggeredTools.add((name, query)),
      )) {
        tokens.add(token);
      }

      final finalOutput = tokens.join();
      expect(finalOutput, equals('马德里明天多云，5到19度，不用带伞。'));
      expect(finalOutput, isNot(contains('DSML')));
      expect(triggeredTools, equals([('web_search', '马德里 明天 天气')]));
    });

    test('extractLocationFromWeatherQuery 准确剥离时间与天气词提取城市名', () {
      expect(
        WebSearchService.extractLocationFromWeatherQuery(
            '马德里 2026年10月24日 明天 天气预报'),
        equals('马德里'),
      );
      expect(
        WebSearchService.extractLocationFromWeatherQuery(
            'Madrid October 24 2026 weather forecast tomorrow'),
        equals('Madrid'),
      );
    });
  });
}
