import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/support/gemini_live_capabilities.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_protocol.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_setup.dart';

void main() {
  group('1. GeminiLiveCapabilities 矩阵与规范化测试', () {
    test('resolveAdvanced 判定矩阵', () {
      // 显式 advanced 模式强制为 true
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'advanced',
          model: 'gemini-2.0-flash',
        ),
        isTrue,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'ADVANCED',
          model: 'any-model',
        ),
        isTrue,
      );

      // 显式 basic 模式强制为 false
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'basic',
          model: 'gemini-3.8-live-extended-thinking',
        ),
        isFalse,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'BASIC',
          model: 'models/gemini-3.8-live-extended-thinking',
        ),
        isFalse,
      );

      // auto / 空 / 未知模式根据 model 名字探测 extended-thinking
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'auto',
          model: 'gemini-3.8-live-extended-thinking',
        ),
        isTrue,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'auto',
          model: 'models/gemini-3.8-live-extended-thinking',
        ),
        isTrue,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'auto',
          model: 'gemini-2.5-flash',
        ),
        isFalse,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: '',
          model: 'gemini-3.8-live-extended-thinking',
        ),
        isTrue,
      );
      expect(
        GeminiLiveCapabilities.resolveAdvanced(
          mode: 'unknown',
          model: 'gemini-3.8-live-preview',
        ),
        isFalse,
      );
    });

    test('normalizeThinkingLevel 深度规范化', () {
      expect(
          GeminiLiveCapabilities.normalizeThinkingLevel('low'), equals('low'));
      expect(
          GeminiLiveCapabilities.normalizeThinkingLevel('LOW'), equals('low'));
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('medium'),
        equals('medium'),
      );
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('MEDIUM'),
        equals('medium'),
      );
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('high'),
        equals('high'),
      );
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('HIGH'),
        equals('high'),
      );

      // 非法或空值回退为 medium
      expect(
          GeminiLiveCapabilities.normalizeThinkingLevel(''), equals('medium'));
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('invalid'),
        equals('medium'),
      );
      expect(
        GeminiLiveCapabilities.normalizeThinkingLevel('max'),
        equals('medium'),
      );
    });
  });

  group('2. GeminiLiveDialogSetup 握手载荷与工具构建测试', () {
    final settings = AppSettings(
      geminiApiKey: 'test-key',
      geminiLiveModel: 'gemini-3.8-live',
      geminiLiveVoice: 'Kore',
      enableWebSearch: true,
      enableLightRag: true,
      lightRagBaseUrl: 'http://127.0.0.1:9621',
      enableOpenCode: true,
    );

    test('Basic 模式（advanced=false）不含 thinkingConfig 且工具无 behavior', () {
      final setupMap = GeminiLiveDialogSetup.buildSetupMessage(
        settings: settings,
        advanced: false,
      );
      final setup = setupMap['setup'] as Map<String, dynamic>;
      final genCfg = setup['generationConfig'] as Map<String, dynamic>;

      expect(genCfg.containsKey('thinkingConfig'), isFalse);

      final tools = setup['tools'] as List<dynamic>;
      final fnTool = tools.firstWhere(
        (t) => (t as Map).containsKey('functionDeclarations'),
      ) as Map<String, dynamic>;
      final decls = fnTool['functionDeclarations'] as List<dynamic>;

      expect(decls.isNotEmpty, isTrue);
      for (final d in decls) {
        final declMap = d as Map<String, dynamic>;
        expect(declMap.containsKey('behavior'), isFalse);
      }
    });

    test('Advanced 模式包含 thinkingConfig 且为所有原生工具添加 NON_BLOCKING', () {
      final setupMap = GeminiLiveDialogSetup.buildSetupMessage(
        settings: settings,
        advanced: true,
        thinkingLevel: 'high',
        includeThoughts: true,
      );
      final setup = setupMap['setup'] as Map<String, dynamic>;
      final genCfg = setup['generationConfig'] as Map<String, dynamic>;

      expect(genCfg.containsKey('thinkingConfig'), isTrue);
      final thinkingCfg = genCfg['thinkingConfig'] as Map<String, dynamic>;
      expect(thinkingCfg['thinkingLevel'], equals('high'));
      expect(thinkingCfg['includeThoughts'], isTrue);

      final tools = setup['tools'] as List<dynamic>;
      // googleSearch 不属于 functionDeclaration，不受 NON_BLOCKING 污染
      final googleSearchTool = tools.firstWhere(
        (t) => (t as Map).containsKey('googleSearch'),
      ) as Map<String, dynamic>;
      expect(googleSearchTool.containsKey('behavior'), isFalse);

      final fnTool = tools.firstWhere(
        (t) => (t as Map).containsKey('functionDeclarations'),
      ) as Map<String, dynamic>;
      final decls = fnTool['functionDeclarations'] as List<dynamic>;

      expect(decls.isNotEmpty, isTrue);
      for (final d in decls) {
        final declMap = d as Map<String, dynamic>;
        expect(declMap['behavior'], equals('NON_BLOCKING'));
      }
    });

    test('预览试听 setup 路径强制 thinkingLevel 为 low 且 includeThoughts 为 false', () {
      // 通过 buildSetupMessage(isPreview: true)
      final previewMap = GeminiLiveDialogSetup.buildSetupMessage(
        settings: settings,
        advanced: true,
        thinkingLevel: 'high',
        includeThoughts: true,
        isPreview: true,
      );
      final setup = previewMap['setup'] as Map<String, dynamic>;
      final genCfg = setup['generationConfig'] as Map<String, dynamic>;
      final thinkingCfg = genCfg['thinkingConfig'] as Map<String, dynamic>;

      expect(thinkingCfg['thinkingLevel'], equals('low'));
      expect(thinkingCfg['includeThoughts'], isFalse);

      // 通过专门的 buildPreviewSetupMessage
      final previewHelperMap = GeminiLiveDialogSetup.buildPreviewSetupMessage(
        settings: settings,
        advanced: true,
        thinkingLevel: 'high',
        includeThoughts: true,
      );
      final helperSetup = previewHelperMap['setup'] as Map<String, dynamic>;
      final helperGenCfg =
          helperSetup['generationConfig'] as Map<String, dynamic>;
      final helperThinkingCfg =
          helperGenCfg['thinkingConfig'] as Map<String, dynamic>;

      expect(helperThinkingCfg['thinkingLevel'], equals('low'));
      expect(helperThinkingCfg['includeThoughts'], isFalse);
    });
  });

  group('3. 工具响应载荷 scheduling 测试', () {
    test('schedulingFor 策略映射', () {
      expect(
        GeminiLiveDialogSetup.schedulingFor('record_background_speech'),
        equals('SILENT'),
      );
      expect(
        GeminiLiveDialogSetup.schedulingFor('capture_photo'),
        equals('WHEN_IDLE'),
      );
      expect(
        GeminiLiveDialogSetup.schedulingFor('lightrag_query'),
        equals('WHEN_IDLE'),
      );
      expect(
        GeminiLiveDialogSetup.schedulingFor('call_custom_tool'),
        equals('WHEN_IDLE'),
      );
    });

    test('buildFunctionResponse scheduling 存在与缺省', () {
      final resDefault = GeminiLiveDialogSetup.buildFunctionResponse(
        'call_0',
        'test_tool',
        'result_ok',
      );
      expect(resDefault.containsKey('scheduling'), isFalse);
      expect(resDefault['id'], equals('call_0'));
      expect(resDefault['name'], equals('test_tool'));
      expect(resDefault['response'], equals({'result': 'result_ok'}));

      final resSilent = GeminiLiveDialogSetup.buildFunctionResponse(
        'call_1',
        'record_background_speech',
        'speech_detected',
        scheduling: 'SILENT',
      );
      expect(resSilent['scheduling'], equals('SILENT'));

      final resIdle = GeminiLiveDialogSetup.buildFunctionResponse(
        'call_2',
        'capture_photo',
        'photo_taken',
        scheduling: 'WHEN_IDLE',
      );
      expect(resIdle['scheduling'], equals('WHEN_IDLE'));
    });
  });

  group('4. GeminiLiveDialogProtocol 扩展协议解析测试', () {
    test('Thought 部分调用 onThought 且不计入助手字幕', () {
      final thoughts = <String>[];
      final outputDeltas = <String>[];
      var modelTurnStarted = false;

      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onThought: thoughts.add,
        onOutputTranscript: (delta, fullText, {required bool isFinal}) {
          if (delta.isNotEmpty) outputDeltas.add(delta);
        },
        onModelTurnStarted: () => modelTurnStarted = true,
      );

      final frameWithThought = jsonEncode({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {'thought': true, 'text': '正在思考主人的问题...'},
              {'thought': true, 'text': '得出结论。'},
            ],
          },
        },
      });

      protocol.handleRawFrame(frameWithThought, 1);

      expect(thoughts, equals(['正在思考主人的问题...', '得出结论。']));
      expect(outputDeltas, isEmpty);
      expect(modelTurnStarted, isFalse);
      expect(protocol.currentOutputText, isEmpty);

      // 后续真实文本输出正常触发
      final frameWithRealText = jsonEncode({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {'text': '浩哥你好！'},
            ],
          },
        },
      });
      protocol.handleRawFrame(frameWithRealText, 1);

      expect(modelTurnStarted, isTrue);
      expect(outputDeltas, equals(['浩哥你好！']));
      expect(protocol.currentOutputText, equals('浩哥你好！'));
    });

    test('解析顶层 toolCallCancellation', () {
      final cancelledIds = <List<String>>[];
      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onToolCallsCancelled: cancelledIds.add,
      );

      final cancelFrame = jsonEncode({
        'toolCallCancellation': {
          'ids': ['call_101', 'call_102'],
        },
      });

      protocol.handleRawFrame(cancelFrame, 1);
      expect(cancelledIds.single, equals(['call_101', 'call_102']));
    });

    test('解析 interactionStatus 与 interactionInProgress 状态跟踪', () {
      final statuses = <String>[];
      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onInteractionStatus: statuses.add,
      );

      expect(protocol.interactionInProgress, isFalse);

      // 1. 顶层 interactionStatus: IN_PROGRESS
      protocol.handleRawFrame(
        jsonEncode({'interactionStatus': 'IN_PROGRESS'}),
        1,
      );
      expect(protocol.interactionInProgress, isTrue);
      expect(statuses.last, equals('IN_PROGRESS'));

      // 2. serverContent 级 interaction_status: IDLE
      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {'interaction_status': 'IDLE'},
        }),
        1,
      );
      expect(protocol.interactionInProgress, isFalse);
      expect(statuses.last, equals('IDLE'));

      // 3. serverContent 级 interactionStatus: IN_PROGRESS
      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {'interactionStatus': 'IN_PROGRESS'},
        }),
        1,
      );
      expect(protocol.interactionInProgress, isTrue);

      // 4. 顶层 interaction_status: IDLE
      protocol.handleRawFrame(
        jsonEncode({'interaction_status': 'IDLE'}),
        1,
      );
      expect(protocol.interactionInProgress, isFalse);
    });

    test('解析 generationComplete 信号', () {
      var genCompleteCount = 0;
      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onGenerationComplete: () => genCompleteCount++,
      );

      // serverContent.generationComplete: true
      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {'generationComplete': true},
        }),
        1,
      );
      expect(genCompleteCount, equals(1));

      // serverContent.generationComplete: {}
      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {
            'generationComplete': <String, dynamic>{},
          },
        }),
        1,
      );
      expect(genCompleteCount, equals(2));

      // 顶层 generationComplete: true
      protocol.handleRawFrame(
        jsonEncode({'generationComplete': true}),
        1,
      );
      expect(genCompleteCount, equals(3));
    });
  });
}
