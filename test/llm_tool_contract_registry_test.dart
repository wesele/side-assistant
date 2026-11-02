import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/core/ports/knowledge_port.dart';
import 'package:side_assistant/core/ports/llm_tool.dart';
import 'package:side_assistant/services/lightrag/lightrag_service.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/llm/tools/capture_photo_tool.dart';
import 'package:side_assistant/services/llm/tools/lightrag_tool.dart';
import 'package:side_assistant/services/llm/tools/web_search_tool.dart';
import 'package:side_assistant/services/llm/web_search_service.dart';

class _MockKnowledgePort implements KnowledgePort {
  String? lastQuery;
  String? lastMode;
  String cannedResponse = 'mock knowledge result';

  @override
  Future<String> queryContext(String query, {String mode = 'mix'}) async {
    lastQuery = query;
    lastMode = mode;
    return cannedResponse;
  }

  @override
  Future<void> archiveSession(ChatSession session) async {}

  @override
  Future<void> retryPending() async {}
}

class _DummyTool implements LlmTool {
  @override
  final String name;
  final bool enabled;
  String? lastArguments;

  _DummyTool({required this.name, this.enabled = true});

  @override
  Map<String, dynamic> get definition => {
        'type': 'function',
        'function': {
          'name': name,
          'description': 'Dummy tool description for $name',
          'parameters': {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
            },
          },
        },
      };

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) => enabled;

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    lastArguments = rawArguments;
    return 'Result from $name: $rawArguments';
  }
}

void main() {
  group('1. LlmToolRegistry Lifecycle & Dispatching Tests', () {
    test('Registry basic CRUD: register, unregister, getTool, operator[]', () {
      final registry = LlmToolRegistry();
      expect(registry.tools, isEmpty);
      expect(registry.hasTool('dummy'), isFalse);

      final toolA = _DummyTool(name: 'tool_a');
      final toolB = _DummyTool(name: 'tool_b');

      registry.register(toolA);
      expect(registry.hasTool('tool_a'), isTrue);
      expect(registry.getTool('tool_a'), equals(toolA));
      expect(registry['tool_a'], equals(toolA));
      expect(registry.toolNames, contains('tool_a'));

      registry.registerAll([toolB]);
      expect(registry.tools.length, equals(2));

      final removed = registry.unregister('tool_a');
      expect(removed, equals(toolA));
      expect(registry.hasTool('tool_a'), isFalse);
      expect(registry.getTool('tool_a'), isNull);

      registry.clear();
      expect(registry.tools, isEmpty);
    });

    test('Registry constructor initializes with initial tool list', () {
      final tool1 = _DummyTool(name: 't1');
      final tool2 = _DummyTool(name: 't2');
      final registry = LlmToolRegistry([tool1, tool2]);

      expect(registry.toolNames.toList(), equals(['t1', 't2']));
    });

    test('getEnabledDefinitions correctly filters based on isEnabled', () {
      final registry = LlmToolRegistry([
        _DummyTool(name: 'enabled_tool', enabled: true),
        _DummyTool(name: 'disabled_tool', enabled: false),
      ]);

      final defs = registry.getEnabledDefinitions(AppSettings());
      expect(defs.length, equals(1));
      expect(defs.first['function']['name'], equals('enabled_tool'));
      expect(registry.isToolEnabled('enabled_tool', AppSettings()), isTrue);
      expect(registry.isToolEnabled('disabled_tool', AppSettings()), isFalse);
      expect(registry.isToolEnabled('unknown_tool', AppSettings()), isFalse);
    });

    test('execute dispatches to matching tool or returns unsupported message',
        () async {
      final dummy = _DummyTool(name: 'calculator');
      final registry = LlmToolRegistry([dummy]);

      final result = await registry.execute('calculator', '{"val": 42}');
      expect(result, equals('Result from calculator: {"val": 42}'));
      expect(dummy.lastArguments, equals('{"val": 42}'));

      final fallback = await registry.execute('non_existent', '{}');
      expect(fallback, equals('Unsupported tool: non_existent'));
    });
  });

  group('2. WebSearchTool Unit Tests', () {
    test('OpenAI Schema compliance and naming', () {
      final tool = WebSearchTool();
      expect(tool.name, equals('web_search'));

      final schema = tool.definition;
      expect(schema['type'], equals('function'));
      final fn = schema['function'] as Map<String, dynamic>;
      expect(fn['name'], equals('web_search'));
      expect(fn['description'], contains('Search the web'));
      final props = fn['parameters']['properties'] as Map<String, dynamic>;
      expect(props.containsKey('query'), isTrue);
      expect(fn['parameters']['required'], contains('query'));
    });

    test('isEnabled dynamically reflects settings.enableWebSearch', () {
      final tool = WebSearchTool();
      expect(tool.isEnabled(AppSettings(enableWebSearch: true)), isTrue);
      expect(tool.isEnabled(AppSettings(enableWebSearch: false)), isFalse);
    });

    test('extractQuery robust parameter parsing', () {
      // 1. Standard JSON with query
      expect(
        WebSearchTool.extractQuery('{"query": "Flutter 3.29 release"}'),
        equals('Flutter 3.29 release'),
      );

      // 2. Alternative key 'q'
      expect(
        WebSearchTool.extractQuery('{"q": "Beijing weather"}'),
        equals('Beijing weather'),
      );

      // 3. Alternative key 'keyword'
      expect(
        WebSearchTool.extractQuery('{"keyword": "SideAssistant architecture"}'),
        equals('SideAssistant architecture'),
      );

      // 4. Raw string in JSON
      expect(
        WebSearchTool.extractQuery('"just a plain string"'),
        equals('just a plain string'),
      );

      // 5. Malformed JSON with regex fallback
      expect(
        WebSearchTool.extractQuery(
            'some prefix {"query": "malformed test"} tail'),
        equals('malformed test'),
      );

      // 6. Empty / blank string
      expect(WebSearchTool.extractQuery('   '), equals(''));
    });

    test('execute executes searchService and returns formatted results',
        () async {
      final fakeClient = MockClient((req) async {
        return http.Response.bytes(
          utf8.encode('''
          <ol id="b_results">
            <li class="b_algo">
              <h2><a href="https://dart.dev">Dart SDK</a></h2>
              <p>Dart is an approachable, portable, and productive language.</p>
            </li>
          </ol>
          '''),
          200,
        );
      });

      final searchService = WebSearchService(client: fakeClient);
      final tool = WebSearchTool(searchService: searchService);

      final res = await tool.execute('{"query": "Dart language"}');
      expect(res, contains('Dart SDK'));
      expect(res, contains('https://dart.dev'));

      final emptyRes = await tool.execute('   ');
      expect(emptyRes, contains('搜索关键词为空'));
    });
  });

  group('3. LightRagTool Unit Tests', () {
    test('OpenAI Schema compliance and naming', () {
      final tool = LightRagTool();
      expect(tool.name, equals('lightrag_query'));

      final schema = tool.definition;
      expect(schema['type'], equals('function'));
      final fn = schema['function'] as Map<String, dynamic>;
      expect(fn['name'], equals('lightrag_query'));
      expect(fn['description'], contains('LightRAG'));
      final props = fn['parameters']['properties'] as Map<String, dynamic>;
      expect(props.containsKey('query'), isTrue);
      expect(props.containsKey('mode'), isTrue);
      expect(
          props['mode']['enum'], equals(['mix', 'local', 'global', 'naive']));
    });

    test(
        'isEnabled checks enableLightRag, baseUrl and knowledgePort availability',
        () {
      final mockPort = _MockKnowledgePort();
      final toolWithPort = LightRagTool(knowledgePort: mockPort);
      final toolWithoutPort = LightRagTool(knowledgePort: null);

      expect(
        toolWithPort.isEnabled(AppSettings(
          enableLightRag: true,
          lightRagBaseUrl: 'http://192.168.31.233:9621',
        )),
        isTrue,
      );

      // Disabled when flag is false
      expect(
        toolWithPort.isEnabled(AppSettings(
          enableLightRag: false,
          lightRagBaseUrl: 'http://192.168.31.233:9621',
        )),
        isFalse,
      );

      // Disabled when baseUrl is empty
      expect(
        toolWithPort.isEnabled(AppSettings(
          enableLightRag: true,
          lightRagBaseUrl: '   ',
        )),
        isFalse,
      );

      // Disabled when knowledgePort is null
      expect(
        toolWithoutPort.isEnabled(AppSettings(
          enableLightRag: true,
          lightRagBaseUrl: 'http://192.168.31.233:9621',
        )),
        isFalse,
      );
    });

    test('extractMode correctly maps hybrid to mix and preserves valid modes',
        () {
      expect(LightRagTool.extractMode('{"mode": "local"}'), equals('local'));
      expect(LightRagTool.extractMode('{"mode": "global"}'), equals('global'));
      expect(LightRagTool.extractMode('{"mode": "naive"}'), equals('naive'));
      expect(LightRagTool.extractMode('{"mode": "hybrid"}'), equals('mix'));
      expect(LightRagTool.extractMode('{}'), equals('mix'));
      expect(LightRagTool.extractMode('invalid json'), equals('mix'));
    });

    test('execute invokes knowledgePort with extracted parameters', () async {
      final mockPort = _MockKnowledgePort();
      final tool = LightRagTool(knowledgePort: mockPort);

      final out = await tool.execute('{"query": "浩哥的生日是哪天", "mode": "local"}');
      expect(out, equals('mock knowledge result'));
      expect(mockPort.lastQuery, equals('浩哥的生日是哪天'));
      expect(mockPort.lastMode, equals('local'));

      final outHybrid = await tool.execute('{"query": "日程", "mode": "hybrid"}');
      expect(outHybrid, equals('mock knowledge result'));
      expect(mockPort.lastMode, equals('mix'));
    });

    test('execute handles missing knowledgePort and empty query gracefully',
        () async {
      final unconfiguredTool = LightRagTool(knowledgePort: null);
      final res1 = await unconfiguredTool.execute('{"query": "test"}');
      expect(res1, contains('未配置或未启用'));

      final configuredTool = LightRagTool(knowledgePort: _MockKnowledgePort());
      final res2 = await configuredTool.execute('{"query": "   "}');
      expect(res2, contains('查询内容为空'));
    });
  });

  group('4. CapturePhotoTool Unit Tests', () {
    test('OpenAI Schema compliance and naming', () {
      const tool = CapturePhotoTool();
      expect(tool.name, equals('capture_photo'));

      final schema = tool.definition;
      expect(schema['type'], equals('function'));
      final fn = schema['function'] as Map<String, dynamic>;
      expect(fn['name'], equals('capture_photo'));
      expect(fn['description'], contains('随身摄像头'));
    });

    test('isEnabled is true only when context has onCapturePhoto', () {
      const tool = CapturePhotoTool();

      expect(tool.isEnabled(AppSettings(), context: null), isFalse);
      expect(
        tool.isEnabled(
          AppSettings(),
          context: const LlmToolContext(),
        ),
        isFalse,
      );
      expect(
        tool.isEnabled(
          AppSettings(),
          context: LlmToolContext(
            onCapturePhoto: () async => Uint8List.fromList([1, 2, 3]),
          ),
        ),
        isTrue,
      );
    });

    test('execute captures photo and notifies onPhotoCaptured', () async {
      const tool = CapturePhotoTool();
      Uint8List? capturedBytes;
      final mockBytes = Uint8List.fromList([10, 20, 30, 40]);

      final context = LlmToolContext(
        onCapturePhoto: () async => mockBytes,
        onPhotoCaptured: (bytes) => capturedBytes = bytes,
      );

      final result = await tool.execute('{"reason": "识别人脸"}', context: context);
      expect(result, contains('现场照片拍摄成功'));
      expect(capturedBytes, equals(mockBytes));
    });

    test('execute handles camera return null and camera exception', () async {
      const tool = CapturePhotoTool();

      // Case 1: no onCapturePhoto configured
      final noCtxResult = await tool.execute('{}');
      expect(noCtxResult, contains('未配置拍照功能'));

      // Case 2: onCapturePhoto returns null
      final nullResult = await tool.execute(
        '{}',
        context: LlmToolContext(onCapturePhoto: () async => null),
      );
      expect(nullResult, contains('未能获取到相机画面'));

      // Case 3: onCapturePhoto throws exception
      final errResult = await tool.execute(
        '{}',
        context: LlmToolContext(
          onCapturePhoto: () async =>
              throw Exception('Hardware camera disconnected'),
        ),
      );
      expect(errResult, contains('拍照异常'));
      expect(errResult, contains('Hardware camera disconnected'));
    });
  });

  group('5. KnowledgePort & LightRagService Contract Verification', () {
    test('LightRagService implements KnowledgePort queryContext contract',
        () async {
      final fakeClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'response': '浩哥喜欢摄影和写代码',
          }),
          200,
        );
      });

      final KnowledgePort service = LightRagService(
        baseUrl: 'http://localhost:9621',
        client: fakeClient,
      );

      final result = await service.queryContext('浩哥的爱好');
      expect(result, contains('浩哥喜欢摄影和写代码'));
    });
  });

  group('6. LlmService Decoupled Tool Integration & Backward Compatibility',
      () {
    test('LlmService constructor with custom LlmToolRegistry', () {
      final customRegistry = LlmToolRegistry([
        _DummyTool(name: 'custom_tool'),
      ]);

      final service = LlmService(
        settings: AppSettings(),
        toolRegistry: customRegistry,
      );

      expect(service.toolRegistry, equals(customRegistry));
      expect(service.toolRegistry.hasTool('custom_tool'), isTrue);
    });

    test(
        'LlmService default constructor registers web_search, lightrag_query, capture_photo',
        () {
      final service = LlmService(
        settings: AppSettings(enableWebSearch: true),
      );

      expect(service.toolRegistry.hasTool('web_search'), isTrue);
      expect(service.toolRegistry.hasTool('lightrag_query'), isTrue);
      expect(service.toolRegistry.hasTool('capture_photo'), isTrue);
    });

    test('Static schema getters and helpers maintain backward compatibility',
        () {
      expect(LlmService.webSearchToolDefinition['function']['name'],
          equals('web_search'));
      expect(LlmService.lightRagToolDefinition['function']['name'],
          equals('lightrag_query'));
      expect(LlmService.capturePhotoToolDefinition['function']['name'],
          equals('capture_photo'));

      expect(
        LlmService.extractSearchQuery('{"query": "Hello world"}'),
        equals('Hello world'),
      );
      expect(
        LlmService.extractToolMode('{"mode": "hybrid"}'),
        equals('mix'),
      );
    });
  });
}
