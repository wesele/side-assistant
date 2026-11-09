import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/ui/screens/settings/widgets/pipeline_mode_section.dart';
import 'package:side_assistant/ui/screens/settings_screen.dart';

class _FakeAssistantController extends Fake implements AssistantController {}

class _PipelineModeSectionHost extends StatefulWidget {
  final String initialMode;
  final String initialModel;
  final String initialThinkingLevel;
  final bool initialIncludeThoughts;

  const _PipelineModeSectionHost({
    this.initialMode = AppConstants.geminiLiveAdvancedModeAuto,
    this.initialModel = AppConstants.defaultGeminiLiveModel,
    this.initialThinkingLevel = AppConstants.defaultGeminiLiveThinkingLevel,
    this.initialIncludeThoughts = false,
  });

  @override
  State<_PipelineModeSectionHost> createState() =>
      _PipelineModeSectionHostState();
}

class _PipelineModeSectionHostState extends State<_PipelineModeSectionHost> {
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late String _pipelineMode;
  late String _voice;
  late String _advancedMode;
  late String _thinkingLevel;
  late bool _includeThoughts;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController(text: 'test-key');
    _modelCtrl = TextEditingController(text: widget.initialModel);
    _pipelineMode = AppConstants.pipelineModeGeminiLive;
    _voice = AppConstants.defaultGeminiLiveVoice;
    _advancedMode = widget.initialMode;
    _thinkingLevel = widget.initialThinkingLevel;
    _includeThoughts = widget.initialIncludeThoughts;
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PipelineModeSection(
            controller: _FakeAssistantController(),
            pipelineMode: _pipelineMode,
            onPipelineModeChanged: (v) => setState(() => _pipelineMode = v),
            geminiApiKeyCtrl: _apiKeyCtrl,
            geminiLiveModelCtrl: _modelCtrl,
            geminiLiveVoice: _voice,
            onGeminiLiveVoiceChanged: (v) => setState(() => _voice = v),
            geminiLiveAdvancedMode: _advancedMode,
            onGeminiLiveAdvancedModeChanged: (v) =>
                setState(() => _advancedMode = v),
            geminiLiveThinkingLevel: _thinkingLevel,
            onGeminiLiveThinkingLevelChanged: (v) =>
                setState(() => _thinkingLevel = v),
            geminiLiveIncludeThoughts: _includeThoughts,
            onGeminiLiveIncludeThoughtsChanged: (v) =>
                setState(() => _includeThoughts = v),
            isAndroid: false,
            audioInputDevices: const [],
            audioInputDeviceId: '',
            audioInputDeviceLabel: '',
            isLoadingAudioDevices: false,
            onRefreshAudioDevices: () {},
            onAudioInputDeviceChanged: (_, __) {},
            onAutoSave: ({immediate = false}) {},
          ),
        ),
      ),
    );
  }
}

void main() {
  group('PipelineModeSection Gemini Live 高级配置项测试', () {
    setUp(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.physicalSize =
          const Size(1024, 1600);
      binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    });

    tearDown(() {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first.resetPhysicalSize();
      binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });
    testWidgets('1. 默认 auto 模式且普通模型时，深度思考与摘要开关为禁用状态并展示 helperText',
        (tester) async {
      await tester.pumpWidget(
        const _PipelineModeSectionHost(
          initialMode: AppConstants.geminiLiveAdvancedModeAuto,
          initialModel: 'gemini-3.8-live',
        ),
      );
      await tester.pumpAndSettle();

      // 验证模式下拉框存在
      expect(find.byKey(const Key('gemini_live_advanced_mode_dropdown')),
          findsOneWidget);
      expect(find.text('自动（按模型判断）'), findsOneWidget);

      // 思考深度下拉框处于禁用状态 (onChanged == null)
      final thinkingFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_thinking_level_dropdown')),
      );
      expect(thinkingFormField.onChanged, isNull);
      expect(find.text('初级模式下不生效'), findsWidgets);

      // 显示思考摘要开关处于禁用状态 (onChanged == null)
      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(switchTile.onChanged, isNull);
      expect(switchTile.value, isFalse);
    });

    testWidgets('2. auto 模式且模型包含 extended-thinking 时，思考深度与开关自动启用',
        (tester) async {
      await tester.pumpWidget(
        const _PipelineModeSectionHost(
          initialMode: AppConstants.geminiLiveAdvancedModeAuto,
          initialModel: 'gemini-3.8-live-extended-thinking',
        ),
      );
      await tester.pumpAndSettle();

      final thinkingFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_thinking_level_dropdown')),
      );
      expect(thinkingFormField.onChanged, isNotNull);
      expect(find.text('初级模式下不生效'), findsNothing);

      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(switchTile.onChanged, isNotNull);

      // 点击开关测试可切换
      await tester
          .tap(find.byKey(const Key('gemini_live_include_thoughts_switch')));
      await tester.pumpAndSettle();

      final updatedSwitchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(updatedSwitchTile.value, isTrue);
    });

    testWidgets('3. 显式 advanced 模式下，即便普通模型名称也强制启用思考深度与摘要', (tester) async {
      await tester.pumpWidget(
        const _PipelineModeSectionHost(
          initialMode: AppConstants.geminiLiveAdvancedModeAdvanced,
          initialModel: 'gemini-3.8-live',
          initialThinkingLevel: AppConstants.geminiLiveThinkingLevelHigh,
          initialIncludeThoughts: true,
        ),
      );
      await tester.pumpAndSettle();

      final thinkingFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_thinking_level_dropdown')),
      );
      expect(thinkingFormField.onChanged, isNotNull);
      expect(thinkingFormField.initialValue,
          equals(AppConstants.geminiLiveThinkingLevelHigh));

      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(switchTile.onChanged, isNotNull);
      expect(switchTile.value, isTrue);
      expect(find.text('初级模式下不生效'), findsNothing);
    });

    testWidgets('4. 显式 basic 模式下，即便模型包含 extended-thinking 也强制禁用',
        (tester) async {
      await tester.pumpWidget(
        const _PipelineModeSectionHost(
          initialMode: AppConstants.geminiLiveAdvancedModeBasic,
          initialModel: 'gemini-3.8-live-extended-thinking',
        ),
      );
      await tester.pumpAndSettle();

      final thinkingFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_thinking_level_dropdown')),
      );
      expect(thinkingFormField.onChanged, isNull);

      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(switchTile.onChanged, isNull);
      expect(find.text('初级模式下不生效'), findsWidgets);
    });

    testWidgets('5. 模型预设下拉菜单可供快捷填入预设模型并实时驱动启用态响应', (tester) async {
      await tester.pumpWidget(
        const _PipelineModeSectionHost(
          initialMode: AppConstants.geminiLiveAdvancedModeAuto,
          initialModel: 'gemini-3.8-live',
        ),
      );
      await tester.pumpAndSettle();

      // 初始普通模型：禁用
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('gemini_live_thinking_level_dropdown')),
            )
            .onChanged,
        isNull,
      );

      // 点击后缀图标弹窗预设模型
      final popupBtn = find.byTooltip('选择预设模型');
      expect(popupBtn, findsOneWidget);
      await tester.tap(popupBtn);
      await tester.pumpAndSettle();

      // 弹出选项中应有预设模型
      expect(find.text(AppConstants.geminiLiveExtendedThinkingModel),
          findsOneWidget);

      // 选择 extended-thinking 选项
      await tester.tap(find.text(AppConstants.geminiLiveExtendedThinkingModel));
      await tester.pumpAndSettle();

      // 验证文本框内容已更新
      expect(find.text(AppConstants.geminiLiveExtendedThinkingModel),
          findsOneWidget);

      // 验证由于输入变更，思考深度立即变为可用状态
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('gemini_live_thinking_level_dropdown')),
            )
            .onChanged,
        isNotNull,
      );
    });
  });

  group('SettingsScreen 完整配置流转与持久化测试', () {
    testWidgets('进入 SettingsScreen 能正确呈现当前 AppSettings 中的 Gemini Live 思考配置并更新',
        (tester) async {
      final settings = AppSettings(
        pipelineMode: AppConstants.pipelineModeGeminiLive,
        geminiLiveModel: 'gemini-3.8-live-extended-thinking',
        geminiLiveAdvancedMode: AppConstants.geminiLiveAdvancedModeAdvanced,
        geminiLiveThinkingLevel: AppConstants.geminiLiveThinkingLevelHigh,
        geminiLiveIncludeThoughts: true,
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
      await tester.pumpAndSettle();

      // 验证思考深度初始选中 High
      final thinkingFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_thinking_level_dropdown')),
      );
      expect(thinkingFormField.initialValue,
          equals(AppConstants.geminiLiveThinkingLevelHigh));

      // 验证思考摘要开关初始选中 True
      final switchTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('gemini_live_include_thoughts_switch')),
      );
      expect(switchTile.value, isTrue);

      // 验证模式初始为 Advanced
      final modeFormField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('gemini_live_advanced_mode_dropdown')),
      );
      expect(modeFormField.initialValue,
          equals(AppConstants.geminiLiveAdvancedModeAdvanced));
    });
  });
}
