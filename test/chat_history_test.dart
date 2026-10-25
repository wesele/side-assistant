import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/main.dart';
import 'package:side_assistant/services/storage/chat_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatSession 模型与 ChatHistoryService 持久化测试', () {
    late Directory tempImagesDir;
    late ChatHistoryService historyService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempImagesDir =
          await Directory.systemTemp.createTemp('side_assistant_history_test_');
      historyService = ChatHistoryService(customImagesDir: tempImagesDir);
    });

    tearDown(() async {
      if (await tempImagesDir.exists()) {
        await tempImagesDir.delete(recursive: true);
      }
    });

    test('首条用户消息截取前 20 个字作为默认标题', () {
      expect(
        ChatSession.generateDefaultTitle('你好，请问今天天气怎么样？'),
        equals('你好，请问今天天气怎么样？'),
      );
      expect(
        ChatSession.generateDefaultTitle('一二三四五六七八九十一二三四五六七八九十多余的字'),
        equals('一二三四五六七八九十一二三四五六七八九十'),
      );
      expect(
        ChatSession.generateDefaultTitle('   \n  '),
        equals('新对话'),
      );
    });

    test('会话保存、读取及图片持久化与清理', () async {
      final imgBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final persistedPath = await historyService.persistImage(
        sessionId: 'sess_1',
        messageId: 'msg_1',
        imageBytes: imgBytes,
      );
      expect(persistedPath, isNotNull);
      expect(await File(persistedPath!).exists(), isTrue);

      final now = DateTime.now();
      final session = ChatSession(
        id: 'sess_1',
        title: '视觉提问测试',
        createdAt: now,
        updatedAt: now,
        messages: [
          ChatMessage(
            id: 'msg_1',
            role: 'user',
            content: '这是什么东西',
            timestamp: now,
            sessionId: 'sess_1',
            imagePath: persistedPath,
          ),
          ChatMessage(
            id: 'msg_2',
            role: 'assistant',
            content: '这是一个杯子',
            timestamp: now,
            sessionId: 'sess_1',
          ),
        ],
      );

      await historyService.saveSessions([session]);
      final loaded = await historyService.loadSessions();
      expect(loaded.length, equals(1));
      expect(loaded.first.title, equals('视觉提问测试'));
      expect(loaded.first.messages.length, equals(2));
      expect(loaded.first.messages.first.imagePath, equals(persistedPath));

      // 验证导出单个自包含 HTML 文件（含 Base64 内嵌图片与对话内容）
      final exportService = ChatHistoryService(
        customImagesDir: tempImagesDir,
        customExportDir: tempImagesDir,
      );
      final htmlPath = await exportService.exportSessionsToHtmlFile([session]);
      final htmlFile = File(htmlPath);
      expect(await htmlFile.exists(), isTrue);
      final htmlContent = await htmlFile.readAsString();
      expect(htmlContent, contains('视觉提问测试'));
      expect(htmlContent, contains('这是什么东西'));
      expect(htmlContent, contains('这是一个杯子'));
      expect(htmlContent, contains('data:image/jpeg;base64,'));

      // 删除会话图片后文件应被清理
      await historyService.deleteSessionImages(session);
      expect(await File(persistedPath).exists(), isFalse);
    });
  });

  group('ChatHistoryDrawer 抽屉交互与管理测试', () {
    late Directory tempImagesDir;
    late ChatHistoryService historyService;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tempImagesDir =
          Directory.systemTemp.createTempSync('side_assistant_drawer_test_');
      historyService = ChatHistoryService(
        customImagesDir: tempImagesDir,
        customExportDir: tempImagesDir,
      );
    });

    tearDown(() {
      if (tempImagesDir.existsSync()) {
        tempImagesDir.deleteSync(recursive: true);
      }
    });

    testWidgets('抽屉展示时间分组、搜索过滤、切换对话、重命名、删除与清空', (WidgetTester tester) async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final threeDaysAgo = now.subtract(const Duration(days: 3));
      final tenDaysAgo = now.subtract(const Duration(days: 10));

      final initialSessions = [
        ChatSession(
          id: 's_today',
          title: '今天的量子力学讨论',
          createdAt: now,
          updatedAt: now,
          messages: [
            ChatMessage(
              id: 'm1',
              role: 'user',
              content: '讲讲薛定谔的猫',
              timestamp: now,
              sessionId: 's_today',
            ),
            ChatMessage(
              id: 'm2',
              role: 'assistant',
              content: '薛定谔的猫是一个思想实验。',
              timestamp: now,
              sessionId: 's_today',
            ),
          ],
        ),
        ChatSession(
          id: 's_yesterday',
          title: '昨天的红烧肉菜谱',
          createdAt: yesterday,
          updatedAt: yesterday,
          messages: [
            ChatMessage(
              id: 'm3',
              role: 'user',
              content: '红烧肉怎么做才好吃',
              timestamp: yesterday,
              sessionId: 's_yesterday',
            ),
          ],
        ),
        ChatSession(
          id: 's_7days',
          title: '三天前的Flutter开发',
          createdAt: threeDaysAgo,
          updatedAt: threeDaysAgo,
          messages: [
            ChatMessage(
              id: 'm4',
              role: 'user',
              content: 'Provider 状态管理用法',
              timestamp: threeDaysAgo,
              sessionId: 's_7days',
            ),
          ],
        ),
        ChatSession(
          id: 's_older',
          title: '十天前的旅游计划',
          createdAt: tenDaysAgo,
          updatedAt: tenDaysAgo,
          messages: [
            ChatMessage(
              id: 'm5',
              role: 'user',
              content: '去京都玩五天怎么安排',
              timestamp: tenDaysAgo,
              sessionId: 's_older',
            ),
          ],
        ),
      ];

      await historyService.saveSessions(initialSessions);

      final settings = AppSettings();
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
        chatHistoryService: historyService,
      );
      await controller.loadChatHistory();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
          ],
          child: const SideAssistantApp(),
        ),
      );
      await tester.pump();

      // 冷启动默认处于空白新对话
      expect(controller.messages, isEmpty);
      expect(find.text('随身助理已就绪'), findsOneWidget);

      // 点击左上角菜单图标打开抽屉
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      // 验证四个时间分组与对应会话标题均正常显示
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('过去 7 天'), findsOneWidget);
      expect(find.text('更早'), findsOneWidget);
      expect(find.text('今天的量子力学讨论'), findsOneWidget);
      expect(find.text('昨天的红烧肉菜谱'), findsOneWidget);
      expect(find.text('三天前的Flutter开发'), findsOneWidget);
      expect(find.text('十天前的旅游计划'), findsOneWidget);

      // 测试搜索框按消息内容过滤（搜“薛定谔”）
      await tester.enterText(
        find.byKey(const Key('drawer_search_field')),
        '薛定谔',
      );
      await tester.pumpAndSettle();
      expect(find.text('今天的量子力学讨论'), findsOneWidget);
      expect(find.text('昨天的红烧肉菜谱'), findsNothing);

      // 清空搜索框恢复全部
      await tester.enterText(
        find.byKey(const Key('drawer_search_field')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('昨天的红烧肉菜谱'), findsOneWidget);

      // 点击“今天的量子力学讨论”切换到该历史对话
      await tester.tap(find.byKey(const Key('session_tile_s_today')));
      await tester.pumpAndSettle();

      expect(controller.currentSessionId, equals('s_today'));
      expect(controller.messages.length, equals(2));
      expect(find.text('讲讲薛定谔的猫'), findsOneWidget);
      expect(find.text('薛定谔的猫是一个思想实验。'), findsOneWidget);

      // 再次打开抽屉，测试重命名
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('session_menu_s_today')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('rename_session_input')),
        '量子物理专题',
      );
      await tester.tap(find.byKey(const Key('rename_session_confirm_btn')));
      await tester.pumpAndSettle();

      expect(find.text('量子物理专题'), findsOneWidget);

      // 测试删除单条对话
      await tester.tap(find.byKey(const Key('session_menu_s_yesterday')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('昨天的红烧肉菜谱'), findsNothing);
      expect(controller.sessions.length, equals(3));

      // 验证抽屉底部包含“导出对话历史 (HTML)”按钮
      expect(find.byKey(const Key('drawer_export_html_btn')), findsOneWidget);

      // 测试清空全部历史对话
      await tester.tap(find.byKey(const Key('drawer_clear_all_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear_all_confirm_btn')));
      await tester.pumpAndSettle();

      expect(controller.sessions, isEmpty);
      expect(controller.messages, isEmpty);
      expect(find.text('暂无历史对话'), findsOneWidget);
    });

    testWidgets('点击对话中的图片可触发放大查看（系统查看器未响应时弹出全屏缩放查看器）',
        (WidgetTester tester) async {
      final now = DateTime.now();
      final sessionWithImg = ChatSession(
        id: 's_img',
        title: '带图对话',
        createdAt: now,
        updatedAt: now,
        messages: [
          ChatMessage(
            id: 'm_img_1',
            role: 'user',
            content: '看看这张照片',
            timestamp: now,
            sessionId: 's_img',
            imagePath: 'non_existent_test_img.jpg',
          ),
        ],
      );

      await historyService.saveSessions([sessionWithImg]);
      final controller = AssistantController(
        settings: AppSettings(),
        enableDriverServer: false,
        chatHistoryService: historyService,
      );
      await controller.loadChatHistory();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
          ],
          child: const SideAssistantApp(),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session_tile_s_img')));
      await tester.pumpAndSettle();

      // 找到消息里的图片组件并点击
      final imgFinder = find.byKey(const Key('message_image_m_img_1'));
      expect(imgFinder, findsOneWidget);
      await tester.tap(imgFinder);
      await tester.pumpAndSettle();

      // 验证弹出全屏可缩放图片查看器，并可点击右上角关闭按钮退出
      expect(find.byKey(const Key('fullscreen_image_viewer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('close_fullscreen_image_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullscreen_image_viewer')), findsNothing);
    });
  });
}
