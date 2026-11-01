import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/ports/knowledge_port.dart';
import 'package:side_assistant/core/ports/llm_tool.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/llm/tools/capture_photo_tool.dart';
import 'package:side_assistant/services/llm/tools/lightrag_tool.dart';
import 'package:side_assistant/services/llm/tools/web_search_tool.dart';
import 'package:side_assistant/services/llm/web_search_service.dart';

class _StressKnowledgePort implements KnowledgePort {
  final List<String> receivedQueries = [];
  final List<String> receivedModes = [];
  bool throwException = false;
  String responseText = 'mock knowledge';

  @override
  Future<String> queryContext(String query, {String mode = 'mix'}) async {
    receivedQueries.add(query);
    receivedModes.add(mode);
    if (throwException) {
      throw StateError('Simulated knowledge port failure');
    }
    return responseText;
  }

  @override
  Future<void> archiveSession(dynamic session) async {}

  @override
  Future<void> retryPending() async {}
}

class _SlowTool implements LlmTool {
  @override
  final String name;
  final Duration delay;
  int callCount = 0;

  _SlowTool(this.name, {this.delay = const Duration(milliseconds: 10)});

  @override
  Map<String, dynamic> get definition => {
        'type': 'function',
        'function': {
          'name': name,
          'description': 'Slow tool for concurrency testing',
        },
      };

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) => true;

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    callCount++;
    await Future.delayed(delay);
    return 'Result from $name: $rawArguments';
  }
}

void main() {
  group('Empirical Stress: WebSearchTool & LightRagTool extractQuery boundary fuzzing', () {
    test('extractQuery handles truncated, nested, or malformed JSON without crashing', () {
      final cases = <String, String>{
        '': '',
        '   ': '',
        'raw string without json': 'raw string without json',
        '{"query": "simple query"}': 'simple query',
        '{"q": "short query"}': 'short query',
        '{"keyword": "keyword query"}': 'keyword query',
        '{"query": 12345}': '12345',
        '{"query": true}': 'true',
        '{"query": null}': '',
        '{"query": "   padded query   "}': 'padded query',
        '{"other": "value", "q": "fallback_q"}': 'fallback_q',
        // Malformed / truncated JSON fallback regex
        '{"query": "unterminated string': 'unterminated string',
        '{"q": "truncated with \\"special\\" characters': 'truncated with \\',
        r'{"query": ".*+?[]^${}()|\\regex special"}': r'.*+?[]^${}()|\\regex special',
        // Array input
        '[1, 2, 3]': '[1, 2, 3]',
        // Empty object
        '{}': '{}',
      };

      for (final entry in cases.entries) {
        final webResult = WebSearchTool.extractQuery(entry.key);
        final ragResult = LightRagTool.extractQuery(entry.key);
        expect(webResult, isA<String>());
        expect(ragResult, isA<String>());
      }
    });

    test('extractMode in LightRagTool parses valid, alias, and adversarial modes', () {
      expect(LightRagTool.extractMode('{"mode": "hybrid"}'), 'mix');
      expect(LightRagTool.extractMode('{"mode": "mix"}'), 'mix');
      expect(LightRagTool.extractMode('{"mode": "local"}'), 'local');
      expect(LightRagTool.extractMode('{"mode": "global"}'), 'global');
      expect(LightRagTool.extractMode('{"mode": "naive"}'), 'naive');
      expect(LightRagTool.extractMode('{"mode": 999}'), 'mix');
      expect(LightRagTool.extractMode('{"mode": null}'), 'mix');
      expect(LightRagTool.extractMode('not a json'), 'mix');
      expect(LightRagTool.extractMode(''), 'mix');
    });
  });

  group('Empirical Stress: CapturePhotoTool edge cases', () {
    test('Handles null callback, empty bytes, and exceptions gracefully', () async {
      const tool = CapturePhotoTool();
      final settings = AppSettings();

      // 1. Without callback
      expect(tool.isEnabled(settings, context: null), isFalse);
      final r1 = await tool.execute('{}', context: null);
      expect(r1, contains('未配置拍照功能'));

      // 2. Callback returns null
      final ctxNull = LlmToolContext(onCapturePhoto: () async => null);
      expect(tool.isEnabled(settings, context: ctxNull), isTrue);
      final r2 = await tool.execute('{}', context: ctxNull);
      expect(r2, contains('未能获取到相机画面'));

      // 3. Callback returns empty Uint8List
      final ctxEmpty = LlmToolContext(onCapturePhoto: () async => Uint8List(0));
      final r3 = await tool.execute('{}', context: ctxEmpty);
      expect(r3, contains('未能获取到相机画面'));

      // 4. Callback throws error
      final ctxThrow = LlmToolContext(onCapturePhoto: () async {
        throw TimeoutException('Camera connection timed out');
      });
      final r4 = await tool.execute('{}', context: ctxThrow);
      expect(r4, contains('拍照异常'));
      expect(r4, contains('Camera connection timed out'));

      // 5. Successful capture triggers onPhotoCaptured
      Uint8List? captured;
      final expectedBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final ctxSuccess = LlmToolContext(
        onCapturePhoto: () async => expectedBytes,
        onPhotoCaptured: (b) => captured = b,
      );
      final r5 = await tool.execute('{}', context: ctxSuccess);
      expect(r5, contains('拍摄成功'));
      expect(captured, equals(expectedBytes));
    });
  });

  group('Empirical Stress: LlmToolRegistry concurrency & lifecycle', () {
    test('Handles concurrent executions and dynamic mutation without race conditions', () async {
      final registry = LlmToolRegistry();
      final t1 = _SlowTool('tool_1', delay: const Duration(milliseconds: 5));
      final t2 = _SlowTool('tool_2', delay: const Duration(milliseconds: 5));
      registry.registerAll([t1, t2]);

      final futures = <Future<String>>[];
      for (int i = 0; i < 20; i++) {
        final toolName = (i % 2 == 0) ? 'tool_1' : 'tool_2';
        futures.add(registry.execute(toolName, 'arg_$i'));
      }

      final results = await Future.wait(futures);
      expect(results.length, 20);
      expect(t1.callCount, 10);
      expect(t2.callCount, 10);

      // Dynamic unregister during lookup
      final removed = registry.unregister('tool_1');
      expect(removed, equals(t1));
      expect(registry.hasTool('tool_1'), isFalse);
      expect(await registry.execute('tool_1', 'arg'), contains('Unsupported tool'));

      // Dynamic overwrite
      final t2Replacement = _SlowTool('tool_2', delay: Duration.zero);
      registry.register(t2Replacement);
      expect(registry.getTool('tool_2'), equals(t2Replacement));
    });
  });

  group('Empirical Stress: LlmService multi-tool stream orchestrations', () {
    test('Simultaneous multi-tool calls in single response turn', () async {
      final settings = AppSettings()
        ..openAiBaseUrl = 'https://mock.api/v1'
        ..openAiApiKey = 'mock-key'
        ..openAiModel = 'mock-model'
        ..enableWebSearch = true
        ..enableLightRag = true
        ..lightRagBaseUrl = 'http://127.0.0.1:9621';

      final mockKnowledge = _StressKnowledgePort()
        ..responseText = 'LightRAG mock context for test';

      final mockSearchService = WebSearchService(
        client: MockClient((req) async {
          return http.Response('<html><body>Mock Search Result</body></html>', 200);
        }),
      );

      final registry = LlmToolRegistry();
      registry.register(WebSearchTool(searchService: mockSearchService));
      registry.register(LightRagTool(knowledgePort: mockKnowledge));
      registry.register(const CapturePhotoTool());

      int roundCount = 0;
      final mockClient = MockClient((request) async {
        roundCount++;
        if (roundCount == 1) {
          // LLM emits TWO tool calls in one turn: web_search AND lightrag_query
          final sseData = [
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\": \\"SideAssistant news\\"}"}},{"index":1,"id":"call_2","type":"function","function":{"name":"lightrag_query","arguments":"{\\"query\\": \\"owner preferences\\"}"}}]}}]}',
            'data: [DONE]',
          ].join('\n\n');
          return http.Response(sseData, 200, headers: {'content-type': 'text/event-stream'});
        } else {
          // Second round receives tool outputs and provides final answer
          final bodyJson = jsonDecode(request.body) as Map<String, dynamic>;
          final msgs = bodyJson['messages'] as List;
          final toolMsgs = msgs.where((m) => m['role'] == 'tool').toList();
          expect(toolMsgs.length, 2);
          expect(toolMsgs[0]['name'], 'web_search');
          expect(toolMsgs[1]['name'], 'lightrag_query');

          final sseData = [
            'data: {"choices":[{"delta":{"content":"Based on search and knowledge, here is the answer."}}]}',
            'data: [DONE]',
          ].join('\n\n');
          return http.Response(sseData, 200, headers: {'content-type': 'text/event-stream'});
        }
      });

      final service = LlmService(
        settings: settings,
        toolRegistry: registry,
        client: mockClient,
      );

      final toolCallsLogged = <String>[];
      final chunks = <String>[];
      await for (final chunk in service.sendChatStream(
        history: [],
        newUserContent: 'Please check news and my preferences',
        onToolCall: (name, q) => toolCallsLogged.add('$name:$q'),
      )) {
        chunks.add(chunk);
      }

      expect(toolCallsLogged, contains('web_search:SideAssistant news'));
      expect(toolCallsLogged, contains('lightrag_query:owner preferences'));
      expect(chunks.join(), contains('Based on search and knowledge'));
      expect(mockKnowledge.receivedQueries, contains('owner preferences'));
    });

    test('Dynamic settings reconfiguration reactively updates tool definitions', () {
      final settings = AppSettings()
        ..enableWebSearch = false
        ..enableLightRag = false
        ..lightRagBaseUrl = '';

      final service = LlmService(settings: settings);

      // Initially both disabled
      var defs = service.toolRegistry.getEnabledDefinitions(settings);
      expect(defs.any((d) => d['function']['name'] == 'web_search'), isFalse);
      expect(defs.any((d) => d['function']['name'] == 'lightrag_query'), isFalse);

      // Dynamically toggle web search
      settings.enableWebSearch = true;
      defs = service.toolRegistry.getEnabledDefinitions(settings);
      expect(defs.any((d) => d['function']['name'] == 'web_search'), isTrue);

      // Dynamically reconfigure model config via applyConfig
      service.applyConfig(LlmConfig(
        openAiModel: 'deepseek-chat',
        openAiApiKey: 'test-key-2',
      ));
      expect(service.settings.llm.openAiModel, 'deepseek-chat');
    });
  });
}
