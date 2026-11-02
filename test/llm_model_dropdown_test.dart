import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/ui/screens/settings_screen.dart';

void main() {
  group('1. AppSettings cachedAvailableModels 配置项持久化测试', () {
    test('默认配置中 cachedAvailableModels 初始为空列表', () {
      final settings = AppSettings();
      expect(settings.cachedAvailableModels, isEmpty);
    });

    test('AppSettings 序列化与反序列化保留 cachedAvailableModels', () {
      final settings = AppSettings(
        cachedAvailableModels: ['gpt-4o', 'deepseek-chat', 'qwen-turbo'],
      );
      final map = settings.toMap();
      expect(map['cachedAvailableModels'],
          equals(['gpt-4o', 'deepseek-chat', 'qwen-turbo']));

      final restored = AppSettings.fromMap(map);
      expect(restored.cachedAvailableModels,
          equals(['gpt-4o', 'deepseek-chat', 'qwen-turbo']));

      final defaultRestored = AppSettings.fromMap({});
      expect(defaultRestored.cachedAvailableModels, isEmpty);
    });
  });

  group('2. LlmService.fetchAvailableModels 模型拉取方法测试', () {
    test('空 Base URL 直接返回空列表', () async {
      final models = await LlmService.fetchAvailableModels(baseUrl: '');
      expect(models, isEmpty);
    });

    test('解析 OpenAI 兼容规范 {"data": [{"id": ...}]}', () async {
      final mockClient = MockClient((request) async {
        expect(
            request.url.toString(), equals('https://api.openai.com/v1/models'));
        expect(request.headers['Authorization'], equals('Bearer test-key'));
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'gpt-4o', 'object': 'model'},
              {'id': 'gpt-4o-mini', 'object': 'model'},
              {'id': 'deepseek-chat', 'object': 'model'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final models = await LlmService.fetchAvailableModels(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        client: mockClient,
      );

      expect(models, equals(['deepseek-chat', 'gpt-4o', 'gpt-4o-mini']));
    });

    test('解析 Ollama 格式 {"models": [{"name": ...}]}', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'llama3.2:latest'},
              {'name': 'qwen2.5:7b'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final models = await LlmService.fetchAvailableModels(
        baseUrl: 'http://localhost:11434/v1',
        client: mockClient,
      );

      expect(models, equals(['llama3.2:latest', 'qwen2.5:7b']));
    });

    test('HTTP 401 或 500 异常正确抛出', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Unauthorized', 401);
      });

      expect(
        () => LlmService.fetchAvailableModels(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'wrong-key',
          client: mockClient,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('3. SettingsScreen 大模型下拉选择与手动输入切换测试', () {
    testWidgets('进入设置页面默认展示下拉选择可用模型，且包含初始模型', (tester) async {
      tester.view.physicalSize = const Size(1024, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final settings = AppSettings(
        openAiBaseUrl: '',
        openAiModel: 'WB.deepseek-v4.1-flash',
        cachedAvailableModels: [
          'WB.deepseek-v4.1-flash',
          'CLI.gpt-5.6-terra',
          'Codex.gpt-5.6-luna',
        ],
      );
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
      addTearDown(() => controller.dispose());

      await tester.pumpWidget(
        MaterialApp(
          // ignore: type_argument_not_matching_bounds
          home: ChangeNotifierProvider<AssistantController>.value(
            value: controller,
            child: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 验证存在“模型名称（下拉选择）”输入框
      expect(find.text('模型名称（下拉选择）'), findsOneWidget);
      // 验证展示了当前选中的模型 WB.deepseek-v4.1-flash
      expect(find.text('WB.deepseek-v4.1-flash'), findsWidgets);

      // 点击切换为手动输入按钮
      final manualInputBtn = find.byTooltip('切换为手动输入');
      expect(manualInputBtn, findsOneWidget);
      await tester.tap(manualInputBtn);
      await tester.pump(const Duration(milliseconds: 100));

      // 验证已切换为“模型名称（手动输入）”
      expect(find.text('模型名称（手动输入）'), findsOneWidget);

      // 点击后缀图标切换回下拉选择
      final switchBackBtn = find.byTooltip('切换回下拉选择');
      expect(switchBackBtn, findsOneWidget);
      await tester.tap(switchBackBtn);
      await tester.pump(const Duration(milliseconds: 100));

      // 验证再次返回“模型名称（下拉选择）”
      expect(find.text('模型名称（下拉选择）'), findsOneWidget);
    });
  });
}
