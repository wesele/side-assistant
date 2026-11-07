import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/custom_tool_manifest.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/llm/support/custom_tools_prompt_builder.dart';
import 'package:side_assistant/services/llm/tools/call_custom_tool.dart';
import 'package:side_assistant/services/llm/tools/custom_tool_manager.dart';
import 'package:side_assistant/services/llm/tools/invoke_opencode_tool.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_setup.dart';

void main() {
  group('CustomToolManifest 单元测试', () {
    test('isValidToolName 安全校验', () {
      // 合法名称
      expect(CustomToolManifest.isValidToolName('alarm_clock'), isTrue);
      expect(CustomToolManifest.isValidToolName('my-tool-1'), isTrue);
      expect(CustomToolManifest.isValidToolName('calc123'), isTrue);
      expect(CustomToolManifest.isValidToolName('A_Z-0_9'), isTrue);

      // 非法名称（防止路径穿越、注入及空名）
      expect(CustomToolManifest.isValidToolName(''), isFalse);
      expect(CustomToolManifest.isValidToolName('   '), isFalse);
      expect(CustomToolManifest.isValidToolName('../evil'), isFalse);
      expect(CustomToolManifest.isValidToolName('foo/bar'), isFalse);
      expect(CustomToolManifest.isValidToolName(r'foo\bar'), isFalse);
      expect(CustomToolManifest.isValidToolName('tool name'), isFalse);
      expect(CustomToolManifest.isValidToolName('tool*name'), isFalse);
      expect(CustomToolManifest.isValidToolName('a' * 65), isFalse);
    });

    test('序列化与反序列化（支持 camelCase 与 snake_case）', () {
      const original = CustomToolManifest(
        name: 'alarm_clock',
        summary: '设定闹钟与定时提醒',
        command: 'python3 run.py',
        parametersHint: 'time: HH:mm, message: 提醒内容',
        createdAt: '2026-11-07T12:00:00Z',
      );

      final map = original.toMap();
      expect(map['name'], equals('alarm_clock'));
      expect(map['summary'], equals('设定闹钟与定时提醒'));
      expect(map['command'], equals('python3 run.py'));
      expect(map['parametersHint'], equals('time: HH:mm, message: 提醒内容'));

      final fromCamel = CustomToolManifest.fromMap(map);
      expect(fromCamel, equals(original));

      final snakeMap = {
        'name': 'timer',
        'summary': '倒计时',
        'command': 'bash run.sh',
        'parameters_hint': 'seconds: 秒数',
        'created_at': '2026-11-07T13:00:00Z',
      };
      final fromSnake = CustomToolManifest.fromMap(snakeMap);
      expect(fromSnake.name, equals('timer'));
      expect(fromSnake.summary, equals('倒计时'));
      expect(fromSnake.command, equals('bash run.sh'));
      expect(fromSnake.parametersHint, equals('seconds: 秒数'));
      expect(fromSnake.createdAt, equals('2026-11-07T13:00:00Z'));
    });

    test('toPromptLine 提示词输出格式', () {
      const withHint = CustomToolManifest(
        name: 'alarm_clock',
        summary: '定时闹钟',
        command: 'python3 run.py',
        parametersHint: 'time: HH:mm',
      );
      expect(withHint.toPromptLine(),
          equals('- alarm_clock: 定时闹钟 (参数: time: HH:mm)'));

      const withoutHint = CustomToolManifest(
        name: 'sys_info',
        summary: '查看系统信息',
        command: 'bash info.sh',
      );
      expect(withoutHint.toPromptLine(), equals('- sys_info: 查看系统信息'));
    });
  });

  group('CustomToolManager 核心功能测试', () {
    late Directory tempToolsDir;
    late Directory tempOpencodeDir;

    setUp(() {
      tempToolsDir = Directory.systemTemp.createTempSync('custom_tools_test_');
      tempOpencodeDir =
          Directory.systemTemp.createTempSync('opencode_tmp_test_');
    });

    tearDown(() {
      try {
        if (tempToolsDir.existsSync()) {
          tempToolsDir.deleteSync(recursive: true);
        }
      } catch (_) {}
      try {
        if (tempOpencodeDir.existsSync()) {
          tempOpencodeDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('listToolsSync 扫描、过滤与排序', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
      );

      expect(manager.listToolsSync(), isEmpty);

      // 创建合法工具 1: z_tool
      final zDir = Directory(p.join(tempToolsDir.path, 'z_tool'))..createSync();
      File(p.join(zDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'z_tool',
          'summary': 'Z 结尾工具',
          'command': 'echo z',
        }),
      );

      // 创建合法工具 2: a_tool
      final aDir = Directory(p.join(tempToolsDir.path, 'a_tool'))..createSync();
      File(p.join(aDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'a_tool',
          'summary': 'A 开头工具',
          'command': 'echo a',
          'parametersHint': 'arg1: 字符串',
        }),
      );

      // 创建畸变目录：无 tool.json
      Directory(p.join(tempToolsDir.path, 'empty_tool')).createSync();

      // 创建非法工具名目录
      final invalidDir = Directory(p.join(tempToolsDir.path, 'bad tool!'))
        ..createSync();
      File(p.join(invalidDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'bad tool!',
          'summary': '非法名称',
          'command': 'echo bad',
        }),
      );

      final tools = manager.listToolsSync();
      expect(tools.length, equals(2));
      // 检查排序（a_tool 在前，z_tool 在后）
      expect(tools[0].name, equals('a_tool'));
      expect(tools[1].name, equals('z_tool'));
    });

    test('deleteTool 删除持久化工具', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
      );

      final toolDir = Directory(p.join(tempToolsDir.path, 'temp_tool'))
        ..createSync();
      File(p.join(toolDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'temp_tool',
          'summary': '待删工具',
          'command': 'echo 1',
        }),
      );

      expect(manager.listToolsSync().length, equals(1));

      // 尝试删除非法名
      expect(manager.deleteTool('../evil'), isFalse);
      // 删除不存在的工具
      expect(manager.deleteTool('not_exist'), isFalse);

      // 正确删除
      expect(manager.deleteTool('temp_tool'), isTrue);
      expect(toolDir.existsSync(), isFalse);
      expect(manager.listToolsSync(), isEmpty);
    });

    test('executeCustomTool 成功执行与环境注入', () async {
      String? capturedExecutable;
      List<String>? capturedArguments;
      String? capturedWorkingDir;
      Map<String, String>? capturedEnv;
      String? capturedStdin;

      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async {
          capturedExecutable = executable;
          capturedArguments = arguments;
          capturedWorkingDir = workingDirectory;
          capturedEnv = environment;
          capturedStdin = stdinText;
          return const CustomToolProcessResult(
            exitCode: 0,
            stdout: '闹钟已成功设置在 08:30',
          );
        },
      );

      final toolDir = Directory(p.join(tempToolsDir.path, 'alarm_clock'))
        ..createSync();
      File(p.join(toolDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'alarm_clock',
          'summary': '设置闹钟',
          'command': 'python3 run.py',
        }),
      );

      final settings = AppSettings(
        webAccessPassword: 'secret_password_123',
        openCodeTimeoutSeconds: 45,
      );

      final result = await manager.executeCustomTool(
        'alarm_clock',
        '{"time": "08:30"}',
        settings: settings,
      );

      expect(result, equals('闹钟已成功设置在 08:30'));
      expect(capturedWorkingDir, equals(toolDir.path));
      expect(capturedStdin, equals('{"time": "08:30"}'));
      expect(capturedEnv!['TOOL_ARGS_JSON'], equals('{"time": "08:30"}'));
      expect(
        capturedEnv!['SIDE_ASSISTANT_SPEAK_URL'],
        contains('/api/speak-text'),
      );
      expect(
        capturedEnv!['SIDE_ASSISTANT_ACCESS_PASSWORD'],
        equals('secret_password_123'),
      );

      if (Platform.isWindows) {
        expect(capturedExecutable, equals('cmd'));
        expect(capturedArguments, equals(['/c', 'python3 run.py']));
      } else {
        expect(capturedExecutable, equals('sh'));
        expect(capturedArguments, equals(['-c', 'python3 run.py']));
      }
    });

    test('executeCustomTool 异常与超长截断处理', () async {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async {
          // 返回超过 8000 字符的输出
          return CustomToolProcessResult(
            exitCode: 0,
            stdout: 'A' * 9000,
          );
        },
      );

      final toolDir = Directory(p.join(tempToolsDir.path, 'big_output'))
        ..createSync();
      File(p.join(toolDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'big_output',
          'summary': '超大输出',
          'command': 'echo big',
        }),
      );

      final result = await manager.executeCustomTool('big_output', '{}');
      expect(result.length, lessThan(9000));
      expect(result, contains('[输出过长，已截断]'));

      // 测试未找到工具
      final notFound = await manager.executeCustomTool('ghost_tool', '{}');
      expect(notFound, contains('未找到名为 "ghost_tool" 的持久化工具'));

      // 测试非法工具名
      final badName = await manager.executeCustomTool('../evil', '{}');
      expect(badName, contains('非法'));
    });

    test('invokeOpenCode 在 persistent 模式下创建工具与兜底合成 tool.json', () async {
      String? capturedWorkingDir;
      Map<String, String>? capturedEnv;

      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async {
          capturedWorkingDir = workingDirectory;
          capturedEnv = environment;
          // 模拟 OpenCode 只生成了 run.py，未显式写 tool.json
          File(p.join(workingDirectory, 'run.py')).writeAsStringSync(
            'print("Hello from synthesized tool")',
          );
          return const CustomToolProcessResult(
            exitCode: 0,
            stdout: 'Script created and tested.',
          );
        },
      );

      final result = await manager.invokeOpenCode(
        taskDescription: '设置后台定时器并在到期时播报语音',
        persistence: 'persistent',
        toolName: 'my_timer',
        toolSummary: '倒计时语音提醒',
        parametersHint: 'seconds: 秒数',
        initialArguments: '{"seconds": 60}',
      );

      expect(result, contains('持久化工具 "my_timer" 创建并注册成功'));
      expect(capturedWorkingDir, equals(p.join(tempToolsDir.path, 'my_timer')));
      expect(capturedEnv!['SIDE_ASSISTANT_SPEAK_URL'],
          contains('/api/speak-text'));

      // 验证兜底合成的 tool.json 存在且内容正确
      final generatedJson =
          File(p.join(tempToolsDir.path, 'my_timer', 'tool.json'));
      expect(generatedJson.existsSync(), isTrue);

      final manifest = CustomToolManifest.fromMap(
        jsonDecode(generatedJson.readAsStringSync()),
      );
      expect(manifest.name, equals('my_timer'));
      expect(manifest.summary, equals('倒计时语音提醒'));
      expect(manifest.command, equals('python3 run.py'));
      expect(manifest.parametersHint, equals('seconds: 秒数'));

      // 验证随后 listToolsSync 能发现此工具
      final tools = manager.listToolsSync();
      expect(tools.any((t) => t.name == 'my_timer'), isTrue);
    });

    test('invokeOpenCode 在 temporary 模式下执行并自动清理临时目录', () async {
      String? createdTempPath;

      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        tempBaseDirResolver: () => tempOpencodeDir,
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async {
          createdTempPath = workingDirectory;
          expect(Directory(workingDirectory).existsSync(), isTrue);
          return const CustomToolProcessResult(
            exitCode: 0,
            stdout: '42',
          );
        },
      );

      final result = await manager.invokeOpenCode(
        taskDescription: '计算斐波那契数列第 20 项',
        persistence: 'temporary',
      );

      expect(result, equals('42'));
      expect(createdTempPath, isNotNull);
      // 验证执行完成后临时目录已被彻底清理销毁
      expect(Directory(createdTempPath!).existsSync(), isFalse);
    });
  });

  group('CallCustomTool 与 InvokeOpenCodeTool 契约适配测试', () {
    test('CallCustomTool 基础契约与执行分发', () async {
      final manager = CustomToolManager(
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async =>
            const CustomToolProcessResult(exitCode: 0, stdout: 'ok'),
      );

      final tool = CallCustomTool(
        toolManager: manager,
        settingsResolver: () => AppSettings(enableOpenCode: true),
      );

      expect(tool.name, equals('call_custom_tool'));
      expect(tool.isEnabled(AppSettings(enableOpenCode: true)), isTrue);
      expect(tool.isEnabled(AppSettings(enableOpenCode: false)), isFalse);
      expect(tool.definition['function']['name'], equals('call_custom_tool'));

      expect(
        CallCustomTool.extractToolSummary('{"tool_name": "alarm_clock"}'),
        equals('alarm_clock'),
      );

      // 缺少 tool_name 时返回错误提示
      final emptyResult = await tool.execute('{}');
      expect(emptyResult, contains('缺少必需的工具名称'));

      // tool 不存在时返回友好提示
      final notFoundResult =
          await tool.execute('{"tool_name": "unknown_tool"}');
      expect(notFoundResult, contains('未找到名为 "unknown_tool" 的持久化工具'));
    });

    test('InvokeOpenCodeTool 基础契约与任务摘要提取', () async {
      final manager = CustomToolManager(
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async =>
            const CustomToolProcessResult(exitCode: 0, stdout: '42'),
      );

      final tool = InvokeOpenCodeTool(
        toolManager: manager,
        settingsResolver: () => AppSettings(enableOpenCode: true),
      );

      expect(tool.name, equals('invoke_opencode'));
      expect(tool.isEnabled(AppSettings(enableOpenCode: true)), isTrue);
      expect(tool.isEnabled(AppSettings(enableOpenCode: false)), isFalse);
      expect(tool.definition['function']['name'], equals('invoke_opencode'));

      expect(
        InvokeOpenCodeTool.extractTaskSummary('{"tool_name": "pomodoro"}'),
        equals('pomodoro'),
      );
      expect(
        InvokeOpenCodeTool.extractTaskSummary(
          '{"task_description": "计算矩阵特征值与奇异值分解"}',
        ),
        equals('计算矩阵特征值与奇异值分解'),
      );

      // 缺少 task_description 时返回错误
      final emptyResult = await tool.execute('{}');
      expect(emptyResult, contains('缺少必需的任务描述'));

      // 正常执行临时任务
      final execResult = await tool.execute(
        '{"task_description": "计算 21 * 2", "persistence": "temporary"}',
      );
      expect(execResult, equals('42'));
    });
  });

  group('CustomToolsPromptBuilder 提示词生成测试', () {
    late Directory tempToolsDir;

    setUp(() {
      tempToolsDir =
          Directory.systemTemp.createTempSync('prompt_builder_test_');
    });

    tearDown(() {
      try {
        if (tempToolsDir.existsSync()) {
          tempToolsDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('当 enableOpenCode 为 false 时返回空串', () {
      final settings = AppSettings(enableOpenCode: false);
      final prompt = CustomToolsPromptBuilder.buildPromptSuffix(settings);
      expect(prompt, isEmpty);
    });

    test('当工具列表为空时生成包含空列表提示与创建指导', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
      );
      final settings = AppSettings(enableOpenCode: true);
      final prompt = CustomToolsPromptBuilder.buildPromptSuffix(
        settings,
        manager: manager,
      );

      expect(prompt, contains('OpenCode'));
      expect(prompt, contains('(当前暂无已注册的持久化工具)'));
      expect(prompt, contains('persistence: "persistent"'));
      expect(prompt, contains('SIDE_ASSISTANT_SPEAK_URL'));
    });

    test('当存在持久化工具时正确列出清单与指导说明', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
      );

      final alarmDir = Directory(p.join(tempToolsDir.path, 'alarm_clock'))
        ..createSync();
      File(p.join(alarmDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'alarm_clock',
          'summary': '定时闹钟提醒',
          'command': 'python3 run.py',
          'parametersHint': 'time: HH:mm',
        }),
      );

      final settings = AppSettings(enableOpenCode: true);
      final prompt = CustomToolsPromptBuilder.buildPromptSuffix(
        settings,
        manager: manager,
      );

      expect(
        prompt,
        contains('- alarm_clock: 定时闹钟提醒 (参数: time: HH:mm)'),
      );
      expect(prompt, contains('call_custom_tool'));
      expect(prompt, contains('invoke_opencode'));
    });
  });

  group('LlmService 与 OpenCode/自定义工具集成测试', () {
    late Directory tempToolsDir;

    setUp(() {
      tempToolsDir = Directory.systemTemp.createTempSync('llm_tools_test_');
    });

    tearDown(() {
      try {
        if (tempToolsDir.existsSync()) {
          tempToolsDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('LlmService 工具注册受 enableOpenCode 控制', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
      );

      final llmService = LlmService(
        settings: AppSettings(enableOpenCode: false),
        customToolManager: manager,
      );

      final disabledTools = llmService.toolRegistry
          .getEnabledDefinitions(AppSettings(enableOpenCode: false));
      final disabledNames = disabledTools
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(disabledNames, isNot(contains('call_custom_tool')));
      expect(disabledNames, isNot(contains('invoke_opencode')));

      final enabledTools = llmService.toolRegistry
          .getEnabledDefinitions(AppSettings(enableOpenCode: true));
      final enabledNames = enabledTools
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(
          enabledNames, containsAll(['call_custom_tool', 'invoke_opencode']));
    });

    test('buildDialogueIntentSystemPrompt 提示词条件注入', () {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
      );

      final promptDisabled = LlmService.buildDialogueIntentSystemPrompt(
        settings: AppSettings(enableOpenCode: false),
        isInContinuousMode: false,
        customToolManager: manager,
      );
      expect(promptDisabled, isNot(contains('扩展工具与代码生成生态 (OpenCode)')));
      expect(promptDisabled, contains('【输出格式铁律】：'));

      final promptEnabled = LlmService.buildDialogueIntentSystemPrompt(
        settings: AppSettings(enableOpenCode: true),
        isInContinuousMode: false,
        customToolManager: manager,
      );
      expect(promptEnabled, contains('扩展工具与代码生成生态 (OpenCode)'));
      expect(promptEnabled, contains('【输出格式铁律】：'));
    });

    test('sendChatStream 执行 call_custom_tool 端到端流程与摘要回调', () async {
      final manager = CustomToolManager(
        customToolsDirResolver: () => tempToolsDir,
        processRunner: ({
          required executable,
          required arguments,
          required workingDirectory,
          required environment,
          stdinText,
          required timeout,
        }) async =>
            const CustomToolProcessResult(exitCode: 0, stdout: '闹钟设置成功'),
      );

      final toolDir = Directory(p.join(tempToolsDir.path, 'alarm_clock'))
        ..createSync();
      File(p.join(toolDir.path, 'tool.json')).writeAsStringSync(
        jsonEncode({
          'name': 'alarm_clock',
          'summary': '闹钟',
          'command': 'python3 run.py',
        }),
      );

      final round1 = jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_abc',
                  'function': {
                    'name': 'call_custom_tool',
                    'arguments':
                        '{"tool_name":"alarm_clock","arguments":{"time":"07:00"}}',
                  },
                }
              ]
            }
          }
        ]
      });

      final round2 = jsonEncode({
        'choices': [
          {
            'delta': {'content': '已帮浩哥设好07:00闹钟啦'}
          }
        ]
      });

      String? capturedToolName;
      String? capturedQuery;
      int requestCount = 0;

      final mockClient = MockClient((request) async {
        requestCount++;
        final chunk = requestCount == 1 ? round1 : round2;
        return http.Response.bytes(
          utf8.encode('data: $chunk\n\ndata: [DONE]\n\n'),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      });

      final llmService = LlmService(
        settings: AppSettings(enableOpenCode: true),
        customToolManager: manager,
        client: mockClient,
      );

      final stream = llmService.sendChatStream(
        history: [],
        newUserContent: '帮我定一个明早7点的闹钟',
        onToolCall: (name, q) {
          capturedToolName = name;
          capturedQuery = q;
        },
      );

      final result = await stream.join();
      expect(result, contains('已帮浩哥设好07:00闹钟啦'));
      expect(capturedToolName, equals('call_custom_tool'));
      expect(capturedQuery, equals('alarm_clock'));
      expect(requestCount, equals(2));
    });
  });

  group('GeminiLiveDialogSetup 与 OpenCode 工具声明测试', () {
    test('buildSystemInstruction 包含 OpenCode 提示词', () {
      final settingsOn = AppSettings(enableOpenCode: true);
      final instructionOn =
          GeminiLiveDialogSetup.buildSystemInstruction(settingsOn);
      expect(instructionOn, contains('扩展工具与代码生成生态 (OpenCode)'));

      final settingsOff = AppSettings(enableOpenCode: false);
      final instructionOff =
          GeminiLiveDialogSetup.buildSystemInstruction(settingsOff);
      expect(instructionOff, isNot(contains('扩展工具与代码生成生态 (OpenCode)')));
    });

    test('buildTools 动态声明 call_custom_tool 与 invoke_opencode', () {
      final settingsOff = AppSettings(enableOpenCode: false);
      final toolsOff = GeminiLiveDialogSetup.buildTools(settingsOff);
      final declsOff = toolsOff
          .where((t) => t.containsKey('functionDeclarations'))
          .expand((t) => t['functionDeclarations'] as List)
          .map((d) => (d as Map)['name'])
          .toList();
      expect(declsOff, isNot(contains('call_custom_tool')));
      expect(declsOff, isNot(contains('invoke_opencode')));

      final settingsOn = AppSettings(enableOpenCode: true);
      final toolsOn = GeminiLiveDialogSetup.buildTools(settingsOn);
      final declsOn = toolsOn
          .where((t) => t.containsKey('functionDeclarations'))
          .expand((t) => t['functionDeclarations'] as List)
          .cast<Map<String, dynamic>>()
          .toList();

      final callTool =
          declsOn.firstWhere((d) => d['name'] == 'call_custom_tool');
      expect(callTool['parameters']['properties']['tool_name']['type'],
          equals('STRING'));
      expect(callTool['parameters']['properties']['arguments']['type'],
          equals('STRING'));

      final invokeTool =
          declsOn.firstWhere((d) => d['name'] == 'invoke_opencode');
      expect(invokeTool['parameters']['properties']['task_description']['type'],
          equals('STRING'));
      expect(
          invokeTool['parameters']['properties']['initial_arguments']['type'],
          equals('STRING'));
    });
  });
}
