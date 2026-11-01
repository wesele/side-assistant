import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/core/ports/knowledge_port.dart';
import 'package:side_assistant/core/ports/llm_tool.dart';
import 'package:side_assistant/services/llm/tools/capture_photo_tool.dart';
import 'package:side_assistant/services/llm/tools/lightrag_tool.dart';
import 'package:side_assistant/services/llm/tools/web_search_tool.dart';
import 'package:side_assistant/services/llm/web_search_service.dart';

class _MockBarrageKnowledgePort implements KnowledgePort {
  String? lastQuery;
  String? lastMode;
  final String cannedResponse = 'barrage knowledge ok';

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

class _BarrageDummyTool implements LlmTool {
  @override
  final String name;
  final bool enabled = true;
  int executionCount = 0;
  String? lastRawArgs;

  _BarrageDummyTool(this.name);

  @override
  Map<String, dynamic> get definition => {
        'type': 'function',
        'function': {
          'name': name,
          'description': 'Barrage tool $name',
          'parameters': {'type': 'object', 'properties': {}},
        },
      };

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) => enabled;

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    executionCount++;
    lastRawArgs = rawArguments;
    return 'Executed $name with $rawArguments';
  }
}

void main() {
  group('1. LlmToolRegistry Lifecycle & Boundary Stress', () {
    test('Empty registry operations return expected values without crashing', () async {
      final registry = LlmToolRegistry();

      expect(registry.tools, isEmpty);
      expect(registry.toolNames, isEmpty);
      expect(registry.hasTool('dummy'), isFalse);
      expect(registry.hasTool(''), isFalse);
      expect(registry.getTool('dummy'), isNull);
      expect(registry['dummy'], isNull);
      expect(registry.unregister('dummy'), isNull);

      final defs = registry.getEnabledDefinitions(AppSettings());
      expect(defs, isEmpty);

      expect(registry.isToolEnabled('dummy', AppSettings()), isFalse);

      final result = await registry.execute('dummy', '{"test": 123}');
      expect(result, equals('Unsupported tool: dummy'));

      registry.clear();
      expect(registry.tools, isEmpty);
    });

    test('Duplicate tool registration: cleanly overwrites without duplicating entries', () {
      final registry = LlmToolRegistry();
      final tool1 = _BarrageDummyTool('dup_tool');
      final tool2 = _BarrageDummyTool('dup_tool');

      registry.register(tool1);
      expect(registry.tools.length, equals(1));
      expect(registry.getTool('dup_tool'), same(tool1));

      registry.register(tool2);
      expect(registry.tools.length, equals(1));
      expect(registry.toolNames.toList(), equals(['dup_tool']));
      expect(registry.getTool('dup_tool'), same(tool2));
      expect(registry['dup_tool'], same(tool2));
    });

    test('registerAll with duplicate and overlapping tools', () {
      final registry = LlmToolRegistry();
      final t1 = _BarrageDummyTool('alpha');
      final t2 = _BarrageDummyTool('beta');
      final t3 = _BarrageDummyTool('alpha');
      final t4 = _BarrageDummyTool('gamma');

      registry.registerAll([t1, t2, t3, t4]);
      expect(registry.tools.length, equals(3));
      expect(registry.toolNames.toSet(), equals({'alpha', 'beta', 'gamma'}));
      expect(registry['alpha'], same(t3));
    });

    test('Unregister nonexistent and idempotence', () {
      final registry = LlmToolRegistry();
      final t1 = _BarrageDummyTool('my_tool');
      registry.register(t1);

      expect(registry.unregister('my_tool'), same(t1));
      expect(registry.hasTool('my_tool'), isFalse);
      expect(registry.unregister('my_tool'), isNull);
      expect(registry.unregister('nonexistent'), isNull);
      expect(registry.unregister(''), isNull);
      expect(registry.tools, isEmpty);
    });

    test('Unusual and edge tool names (empty, spaces, unicode, punctuation, emojis)', () {
      final registry = LlmToolRegistry();
      final weirdNames = [
        '',
        '   ',
        'tool with spaces',
        'tool/with/slashes',
        'tool.with.dots',
        '🚀_emoji_tool_🔥',
        '__proto__',
        'constructor',
        'null',
        'undefined',
        '中文工具名',
      ];

      for (final name in weirdNames) {
        final tool = _BarrageDummyTool(name);
        registry.register(tool);
        expect(registry.hasTool(name), isTrue);
        expect(registry.getTool(name), same(tool));
        expect(registry[name], same(tool));
      }

      expect(registry.tools.length, equals(weirdNames.length));

      for (final name in weirdNames) {
        expect(registry.unregister(name), isNotNull);
        expect(registry.hasTool(name), isFalse);
      }
      expect(registry.tools, isEmpty);
    });

    test('High volume stress: 1000 tool registrations and lookups', () {
      final registry = LlmToolRegistry();
      const count = 1000;
      final tools = List.generate(count, (i) => _BarrageDummyTool('tool_$i'));

      registry.registerAll(tools);
      expect(registry.tools.length, equals(count));

      for (var i = 0; i < count; i += 2) {
        expect(registry.hasTool('tool_$i'), isTrue);
        expect(registry['tool_$i']!.name, equals('tool_$i'));
      }

      registry.clear();
      expect(registry.tools, isEmpty);
      expect(registry.toolNames, isEmpty);
    });

    test('Concurrent async execute dispatch stress (200 requests)', () async {
      final registry = LlmToolRegistry();
      final toolA = _BarrageDummyTool('worker_a');
      final toolB = _BarrageDummyTool('worker_b');
      registry.registerAll([toolA, toolB]);

      final futures = <Future<String>>[];
      for (var i = 0; i < 200; i++) {
        if (i % 3 == 0) {
          futures.add(registry.execute('worker_a', '{"id": $i}'));
        } else if (i % 3 == 1) {
          futures.add(registry.execute('worker_b', '{"id": $i}'));
        } else {
          futures.add(registry.execute('nonexistent_$i', '{"id": $i}'));
        }
      }

      final results = await Future.wait(futures);
      expect(results.length, equals(200));
      expect(toolA.executionCount, greaterThan(0));
      expect(toolB.executionCount, greaterThan(0));

      for (var i = 0; i < 200; i++) {
        if (i % 3 == 2) {
          expect(results[i], startsWith('Unsupported tool: nonexistent_'));
        } else {
          expect(results[i], startsWith('Executed worker_'));
        }
      }
    });

    test('LlmToolContext copyWith edge cases and immutability', () {
      const original = LlmToolContext(
        sessionId: 'session-123',
        extra: {'key1': 'val1'},
      );

      final copy1 = original.copyWith();
      expect(copy1.sessionId, equals('session-123'));
      expect(copy1.extra, equals({'key1': 'val1'}));
      expect(copy1.onCapturePhoto, isNull);
      expect(copy1.onPhotoCaptured, isNull);

      final copy2 = original.copyWith(
        sessionId: 'session-456',
        extra: {'key2': 'val2'},
      );
      expect(copy2.sessionId, equals('session-456'));
      expect(copy2.extra, equals({'key2': 'val2'}));
      expect(original.sessionId, equals('session-123'));
    });
  });

  group('2. Adversarial Raw Arguments Parsing Fuzzing', () {
    final adversarialCorruptedInputs = <String, String>{
      'empty': '',
      'spaces': '     ',
      'newlines and tabs': '\n\r\t \t\r\n',
      'unquoted json key': '{query: "foo"}',
      'unclosed bracket': '{"query": "bar"',
      'trailing comma': '{"query": "baz",}',
      'random noise': 'this is not json at all',
      'partial tag': '<tool_call>{"query": "tag_query"}</tool_call>',
      'json inside surrounding text': 'Prefix text {"query": "embedded"} suffix',
      'multiple json brackets': '{"query": "one"} {"query": "two"}',
      'nested broken braces': '{{{"query": "nested"}}}',
      'empty map': '{}',
      'unrelated key map': '{"foo": "bar", "count": 42}',
      'q key': '{"q": "from_q"}',
      'keyword key': '{"keyword": "from_keyword"}',
      'null query': '{"query": null}',
      'null q and keyword': '{"q": null, "keyword": null}',
      'number query': '{"query": 123456}',
      'float query': '{"query": 3.14159}',
      'boolean true query': '{"query": true}',
      'boolean false query': '{"query": false}',
      'list query': '{"query": ["hello", "world"]}',
      'nested map query': '{"query": {"sub": "deep"}}',
      'root int': '12345',
      'root float': '99.9',
      'root bool': 'true',
      'root null': 'null',
      'root string': '"quoted string query"',
      'root array': '["query", "in", "array"]',
      'chinese query': '{"query": "浩哥今天天气如何？"}',
      'japanese query': '{"query": "こんにちは世界"}',
      'korean query': '{"query": "안녕하세요 세계"}',
      'arabic rtl query': '{"query": "مرحبا بالعالم"}',
      'emojis & surrogate pairs': '{"query": "🚀🎉🔥 𠮷野家 👨‍👩‍👧‍👦"}',
      'quotes and backslashes': '{"query": "test \\"escaped\\" and \\\\ backslash"}',
      'newlines in string': '{"query": "line 1\\nline 2\\r\\nline 3"}',
      'null byte escape': '{"query": "null\\u0000byte"}',
      'sql injection attempt': '{"query": "\' OR 1=1; DROP TABLE users; --"}',
      'xss attempt': '{"query": "<script>alert(\\"xss\\")</script>"}',
      'path traversal': '{"query": "../../../../etc/passwd"}',
      'command injection': '{"query": "; rm -rf / ;"}',
      'large query 50k': '{"query": "${"A" * 50000}"}',
      'unclosed large quote': '{"query": "${"B" * 30000}',
    };

    test('WebSearchTool.extractQuery handles all adversarial inputs without exception', () {
      for (final entry in adversarialCorruptedInputs.entries) {
        expect(
          () => WebSearchTool.extractQuery(entry.value),
          returnsNormally,
          reason: 'Failed on case: ${entry.key}',
        );
        final extracted = WebSearchTool.extractQuery(entry.value);
        expect(extracted, isA<String>(), reason: 'Result must be String for case: ${entry.key}');
      }
    });

    test('LightRagTool.extractQuery handles all adversarial inputs without exception', () {
      for (final entry in adversarialCorruptedInputs.entries) {
        expect(
          () => LightRagTool.extractQuery(entry.value),
          returnsNormally,
          reason: 'Failed on case: ${entry.key}',
        );
        final extracted = LightRagTool.extractQuery(entry.value);
        expect(extracted, isA<String>(), reason: 'Result must be String for case: ${entry.key}');
      }
    });

    test('LightRagTool.extractMode robustness on all edge inputs', () {
      final modeCases = <String, String>{
        'valid mix': '{"mode": "mix"}',
        'valid local': '{"mode": "local"}',
        'valid global': '{"mode": "global"}',
        'valid naive': '{"mode": "naive"}',
        'hybrid alias': '{"mode": "hybrid"}',
        'empty map': '{}',
        'missing mode': '{"query": "test"}',
        'null mode': '{"mode": null}',
        'number mode': '{"mode": 123}',
        'bool mode': '{"mode": true}',
        'list mode': '{"mode": ["local"]}',
        'map mode': '{"mode": {"inner": "mix"}}',
        'corrupted json': '{mode: broken',
        'empty string': '',
        'whitespace': '   ',
        'plain string': 'local',
      };

      for (final entry in modeCases.entries) {
        expect(
          () => LightRagTool.extractMode(entry.value),
          returnsNormally,
          reason: 'Failed on mode case: ${entry.key}',
        );
        final mode = LightRagTool.extractMode(entry.value);
        expect(mode, isNotEmpty, reason: 'Mode should not be empty for case: ${entry.key}');
      }

      expect(LightRagTool.extractMode('{"mode": "hybrid"}'), equals('mix'));
      expect(LightRagTool.extractMode('{"mode": "local"}'), equals('local'));
      expect(LightRagTool.extractMode('{"mode": "global"}'), equals('global'));
      expect(LightRagTool.extractMode('{"mode": "naive"}'), equals('naive'));
      expect(LightRagTool.extractMode('{"mode": "mix"}'), equals('mix'));
      expect(LightRagTool.extractMode('{}'), equals('mix'));
      expect(LightRagTool.extractMode('invalid'), equals('mix'));
    });
  });

  group('3. WebSearchTool Execution Stress & Network Fault Injection', () {
    test('execute never crashes on any malformed input', () async {
      final fakeClient = MockClient((req) async {
        return http.Response('<html><body>No results</body></html>', 200);
      });
      final tool = WebSearchTool(searchService: WebSearchService(client: fakeClient));

      final testInputs = [
        '',
        '   ',
        '{}',
        '{"other": 123}',
        '{"query": ""}',
        '{"query": "   "}',
        'broken json',
        '{"query": 12345}',
        '{"query": "normal query"}',
      ];

      for (final input in testInputs) {
        expect(() async => await tool.execute(input), returnsNormally);
        final res = await tool.execute(input);
        expect(res, isA<String>());
        expect(res, isNotEmpty);
      }
    });

    test('execute gracefully handles HTTP 500 error from upstream search engine', () async {
      final errorClient = MockClient((req) async {
        return http.Response('Internal Server Error', 500);
      });
      final tool = WebSearchTool(searchService: WebSearchService(client: errorClient));

      final result = await tool.execute('{"query": "test query"}');
      expect(result, contains('No web search results found'));
    });

    test('execute gracefully handles client network exception with multi-engine fallback', () async {
      final throwingClient = MockClient((req) async {
        throw http.ClientException('Network connection failed');
      });
      final tool = WebSearchTool(searchService: WebSearchService(client: throwingClient));

      final result = await tool.execute('{"query": "test query"}');
      expect(result, contains('No web search results found'));
    });
  });

  group('4. LightRagTool Execution Stress & Fault Injection', () {
    test('execute handles missing knowledgePort, empty query, and custom port', () async {
      final toolNoPort = LightRagTool(knowledgePort: null);
      final r1 = await toolNoPort.execute('{"query": "hello"}');
      expect(r1, contains('未配置或未启用'));

      final mockPort = _MockBarrageKnowledgePort();
      final toolWithPort = LightRagTool(knowledgePort: mockPort);
      final r2 = await toolWithPort.execute('{"query": "   "}');
      expect(r2, contains('查询内容为空'));

      final r3 = await toolWithPort.execute('{"query": "🚀 特殊字符测试 \\"quotes\\"", "mode": "hybrid"}');
      expect(r3, equals('barrage knowledge ok'));
      expect(mockPort.lastQuery, contains('特殊字符测试'));
      expect(mockPort.lastMode, equals('mix'));
    });
  });

  group('5. CapturePhotoTool Execution Stress & Hardware Exception Handling', () {
    const tool = CapturePhotoTool();

    test('execute ignores corrupted raw arguments gracefully', () async {
      var photoTaken = false;
      final context = LlmToolContext(
        onCapturePhoto: () async {
          photoTaken = true;
          return Uint8List.fromList([1, 2, 3]);
        },
      );

      final inputs = [
        '',
        '   ',
        'corrupted {json',
        '{"reason": "normal reason"}',
        '{"reason": 12345}',
        '{"reason": null}',
        '{"unexpected_key": [true, false]}',
      ];

      for (final raw in inputs) {
        photoTaken = false;
        final res = await tool.execute(raw, context: context);
        expect(res, contains('现场照片拍摄成功'));
        expect(photoTaken, isTrue);
      }
    });

    test('execute handles empty Uint8List bytes return', () async {
      final context = LlmToolContext(
        onCapturePhoto: () async => Uint8List(0),
      );

      final result = await tool.execute('{}', context: context);
      expect(result, contains('未能获取到相机画面'));
    });

    test('execute catches StateError and Exception thrown by camera driver', () async {
      final contextStateErr = LlmToolContext(
        onCapturePhoto: () async => throw StateError('Camera busy or locked'),
      );
      final res1 = await tool.execute('{}', context: contextStateErr);
      expect(res1, contains('拍照异常'));
      expect(res1, contains('Camera busy or locked'));

      final contextCustomErr = LlmToolContext(
        onCapturePhoto: () async => throw Exception('USB device detached'),
      );
      final res2 = await tool.execute('{}', context: contextCustomErr);
      expect(res2, contains('拍照异常'));
      expect(res2, contains('USB device detached'));
    });
  });

  group('6. Full Registry Dispatching Adversarial Verification', () {
    test('Registry executes all registered tools against adversarial barrage', () async {
      final mockKnowledge = _MockBarrageKnowledgePort();
      final fakeSearchClient = MockClient((req) async {
        return http.Response('''
        <ol id="b_results">
          <li class="b_algo">
            <h2><a href="https://example.com">Result</a></h2>
            <p>Snippet text</p>
          </li>
        </ol>
        ''', 200);
      });

      final webTool = WebSearchTool(searchService: WebSearchService(client: fakeSearchClient));
      final lightRagTool = LightRagTool(knowledgePort: mockKnowledge);
      const photoTool = CapturePhotoTool();

      final registry = LlmToolRegistry([webTool, lightRagTool, photoTool]);

      final context = LlmToolContext(
        onCapturePhoto: () async => Uint8List.fromList([255, 216, 255]),
      );

      final settings = AppSettings(
        enableWebSearch: true,
        enableLightRag: true,
        lightRagBaseUrl: 'http://127.0.0.1:9621',
      );

      final enabledDefs = registry.getEnabledDefinitions(settings, context: context);
      expect(enabledDefs.length, equals(3));
      final names = enabledDefs.map((d) => d['function']['name']).toSet();
      expect(names, equals({'web_search', 'lightrag_query', 'capture_photo'}));

      final webRes = await registry.execute(
        'web_search',
        '{"query": "Flutter 3.29"}',
        context: context,
      );
      expect(webRes, contains('Result'));

      final ragRes = await registry.execute(
        'lightrag_query',
        '{"query": "浩哥", "mode": "hybrid"}',
        context: context,
      );
      expect(ragRes, equals('barrage knowledge ok'));

      final photoRes = await registry.execute(
        'capture_photo',
        '{"reason": "拍照"}',
        context: context,
      );
      expect(photoRes, contains('现场照片拍摄成功'));

      final unknownRes = await registry.execute(
        '__unknown_tool__',
        '{}',
        context: context,
      );
      expect(unknownRes, equals('Unsupported tool: __unknown_tool__'));
    });
  });
}
