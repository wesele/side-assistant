import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/main.dart';

void main() {
  testWidgets('SideAssistantApp 基础渲染烟雾测试', (WidgetTester tester) async {
    final settings = AppSettings();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => AssistantController(settings: settings),
          ),
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
    expect(find.byIcon(Icons.photo_camera), findsOneWidget);
  });
}
