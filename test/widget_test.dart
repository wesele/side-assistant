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

    // 验证标题正常显示
    expect(find.text('随身智能助理'), findsOneWidget);
    // 验证待机状态正常显示
    expect(find.text('低功耗待机中'), findsOneWidget);
  });
}
