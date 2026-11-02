import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/main.dart';

void main() {
  testWidgets('SideAssistantApp 基础渲染烟雾测试', (WidgetTester tester) async {
    final settings = AppSettings();

    // AssistantController 构造时，AssistantEngine 会在 Linux 上调用
    // `pactl` / `amixer`（Process.run）恢复播放音量。如果放在 testWidgets 的
    // fake-async 区域里构造，进程启动依赖的零延时 Timer 永远不会被推进，
    // 测试结束时报 "Pending timers" 而失败（Windows/macOS 不走该分支，本地不复现）。
    // 因此把控制器放到真实异步区域创建，UI 渲染仍留在 fake-async 里 pump。
    late final AssistantController controller;
    await tester.runAsync(() async {
      controller = AssistantController(settings: settings);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          // 分析器按 io 分支（foundation_bridge_io.dart 里的自建 ChangeNotifier）
          // 推断类型，运行时走 Flutter 分支，故此处忽略类型边界告警。
          // ignore: type_argument_not_matching_bounds, could_not_infer
          ChangeNotifierProvider.value(value: controller),
        ],
        child: const SideAssistantApp(),
      ),
    );

    // 验证顶栏无文字标题，且包含左侧历史抽屉入口图标
    expect(find.text('随身智能助理'), findsNothing);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    // 验证待机状态正常显示
    expect(find.text('低功耗待机中'), findsOneWidget);
    // 顶部右侧操作区包含摄像头一键抓拍按钮
    expect(find.byKey(const Key('camera_capture_btn')), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async => controller.dispose());
  });
}
