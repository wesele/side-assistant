import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/llm/llm_service.dart';

void main() {
  group('1. AppSettings disableThinking 配置项测试', () {
    test('默认配置中 disableThinking 初始值正确', () {
      final settings = AppSettings();
      expect(settings.disableThinking, equals(AppConstants.defaultDisableThinking));
      expect(settings.disableThinking, isFalse);
    });

    test('AppSettings 序列化与反序列化保留 disableThinking 状态', () {
      final settings = AppSettings(disableThinking: true);
      final map = settings.toMap();
      expect(map['disableThinking'], isTrue);

      final restored = AppSettings.fromMap(map);
      expect(restored.disableThinking, isTrue);

      final defaultRestored = AppSettings.fromMap({});
      expect(defaultRestored.disableThinking, equals(AppConstants.defaultDisableThinking));
    });

    test('defaultSystemPrompt 包含严禁“回你：”前缀的约束', () {
      expect(AppConstants.defaultSystemPrompt, contains('回你：'));
      expect(AppConstants.defaultSystemPrompt, contains('严禁'));
    });
  });

  group('2. 根据模型名称自动推断关闭思考参数测试', () {
    test('DeepSeek 系列模型自动映射为 thinking: {type: disabled}', () {
      final models = [
        'WB.deepseek-v4.1-flash',
        'DeepSeek.deepseek-v4-flash',
        'deepseek-chat',
        'deepseek-reasoner',
        'DeepSeek-R1',
        'deepseek-ai/DeepSeek-V3',
      ];
      for (final m in models) {
        final params = LlmService.getThinkingDisableParams(m);
        expect(params, equals({'thinking': {'type': 'disabled'}}), reason: 'Model: $m');
      }
    });

    test('Qwen / QwQ 系列模型自动映射为 enable_thinking / chat_template_kwargs', () {
      final models = [
        'ModelScope.Qwen/Qwen3.8-27B',
        'ModelScope.Qwen3.8-Flash-Next',
        'qwen-turbo',
        'qwen-plus',
        'qwen-2.5-72b-instruct',
        'qwq-32b',
      ];
      for (final m in models) {
        final params = LlmService.getThinkingDisableParams(m);
        expect(params['enable_thinking'], isFalse, reason: 'Model: $m');
        expect(params['chat_template_kwargs'], equals({'enable_thinking': false}), reason: 'Model: $m');
      }
    });

    test('OpenAI 推理系列 (o1/o3/o4/gpt-5/gpt-6) 与 Gemini 系列自动映射为 reasoning_effort: none', () {
      final models = [
        'o1',
        'o1-mini',
        'o1-preview',
        'o3',
        'o3-mini',
        'CLI.gpt-6-luna',
        'WB.gpt-6.1-sol',
        'WB.gpt-6-astra',
        'CLI.gemini-3.1-pro-low',
        'CLI.gemini-3.8-flash-high',
        'gemini-2.5-flash',
      ];
      for (final m in models) {
        final params = LlmService.getThinkingDisableParams(m);
        expect(params, equals({'reasoning_effort': 'none'}), reason: 'Model: $m');
      }
    });

    test('Claude / GLM / Kimi / Doubao 系列自动映射为 thinking: {type: disabled}', () {
      final models = [
        'CLI.claude-sonnet-4-6',
        'CLI.claude-opus-4-6-thinking',
        'InkStone.glm-5.3',
        'WB.glm-5.3-flash',
        'nVidia.moonshotai/kimi-k3',
        'doubao-pro-32k',
        'ep-20250101-test',
      ];
      for (final m in models) {
        final params = LlmService.getThinkingDisableParams(m);
        expect(params, equals({'thinking': {'type': 'disabled'}}), reason: 'Model: $m');
      }
    });

    test('未知/通用模型兜底使用行业标准 thinking: {type: disabled}', () {
      final params = LlmService.getThinkingDisableParams('custom-unknown-reasoning-model');
      expect(params, equals({'thinking': {'type': 'disabled'}}));
    });
  });

  group('3. 助理回复过滤“回你：”前缀测试', () {
    // 构造模拟响应流
    Stream<String> createMockLlmStream(List<String> rawDeltas) async* {
      // 借用 LlmService 内部的过滤逻辑
      bool prefixResolved = false;
      final prefixBuffer = StringBuffer();
      final prefixPattern = RegExp(r'^\s*回你[：:,，\s]*');

      for (final content in rawDeltas) {
        if (prefixResolved) {
          yield content;
        } else {
          prefixBuffer.write(content);
          final bufferedStr = prefixBuffer.toString();
          final ltrimmed = bufferedStr.trimLeft();
          if (ltrimmed == '回' || ltrimmed == '回你') {
            continue;
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
    }

    test('多 token 切片流式返回“回你：”被完整剔除', () async {
      final tokens = ['回', '你', '：', '今天', '天气', '很好'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('今天天气很好'));
    });

    test('单 token 包含“回你：”被立即剥离', () async {
      final tokens = ['回你：今天天气很好'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('今天天气很好'));
    });

    test('英文冒号与空格“回你: ”被正确剔除', () async {
      final tokens = ['回你: ', '没问题，', '马上为您查询'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('没问题，马上为您查询'));
    });

    test('带首尾空白与换行的“\\n  回你：”被正确剔除', () async {
      final tokens = ['\n  回你：', '好的！'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('好的！'));
    });

    test('正常以“回”字开头的词（如“回顾历史”）决不误删', () async {
      final tokens = ['回', '顾', '历史', '，展望未来'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('回顾历史，展望未来'));
    });

    test('常规正常回答不受任何影响', () async {
      final tokens = ['您好', '，', '我是晓漫助理'];
      final results = <String>[];
      await for (final token in createMockLlmStream(tokens)) {
        results.add(token);
      }
      expect(results.join(), equals('您好，我是晓漫助理'));
    });
  });

  group('4. LlmService 真实连通性与请求参数测试', () {
    test('开启 disableThinking 时向 DeepSeek 模型发送且过滤“回你：”', () async {
      if (AppConstants.defaultOpenAiApiKey.isEmpty) {
        return;
      }
      final settings = AppSettings(
        openAiBaseUrl: AppConstants.defaultOpenAiBaseUrl,
        openAiApiKey: AppConstants.defaultOpenAiApiKey,
        openAiModel: 'WB.deepseek-v4.1-flash',
        disableThinking: true,
      );
      final service = LlmService(settings: settings);
      final reply = await service.sendChat(
        history: [],
        newUserContent: '请回答：今天是星期几？',
      );
      expect(reply, isNotEmpty);
      expect(reply, isNot(startsWith('回你：')));
      expect(reply, isNot(startsWith('回你:')));
    });
  });
}
