import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/engine/coordinators/session_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/services/storage/chat_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionCoordinator 独立单元与契约测试 (SessionCoordinator Unit Tests)', () {
    late SessionCoordinator coordinator;
    late List<AssistantEngineEvent> emittedEvents;
    late int notifyCount;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      emittedEvents = [];
      notifyCount = 0;

      coordinator = SessionCoordinator(
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        chatHistoryService: ChatHistoryService(),
      );
      await coordinator.loadChatHistory();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('1. 初始化状态正确性与基础契约验证', () {
      expect(coordinator.currentSessionId, isNotEmpty);
      expect(coordinator.messages, isEmpty);
      expect(coordinator.sessions, isEmpty);
      expect(coordinator.isDisposed, isFalse);
      expect(coordinator.sessionManager, isNotNull);
      expect(coordinator.chatHistoryService, isNotNull);
    });

    test('2. 原子追加用户消息与助手空白占位消息 (appendUserAndPlaceholderMessage)', () {
      final initialCount = coordinator.messages.length;
      final pair = coordinator.appendUserAndPlaceholderMessage('你好，测试问题');

      expect(pair.userMsgId, isNotEmpty);
      expect(pair.assistantMsgId, isNotEmpty);
      expect(pair.assistantMsgIndex, equals(initialCount + 1));

      expect(coordinator.messages.length, equals(initialCount + 2));
      expect(coordinator.messages[initialCount].role, equals('user'));
      expect(coordinator.messages[initialCount].content, equals('你好，测试问题'));
      expect(coordinator.messages[initialCount + 1].role, equals('assistant'));
      expect(coordinator.messages[initialCount + 1].content, isEmpty);

      final appendedEvents =
          emittedEvents.whereType<MessageAppendedEvent>().toList();
      expect(appendedEvents.length, equals(2));
      expect(appendedEvents.first.message.role, equals('user'));
      expect(appendedEvents.last.message.role, equals('assistant'));
      expect(notifyCount, greaterThan(0));
    });

    test('3. 流式增量更新助手消息内容 (updateAssistantMessageContent)', () {
      final pair = coordinator.appendUserAndPlaceholderMessage('计算 1+1');
      coordinator.updateAssistantMessageContent(
        pair.assistantMsgId,
        pair.assistantMsgIndex,
        '计算中...',
      );

      expect(
        coordinator.messages[pair.assistantMsgIndex].content,
        equals('计算中...'),
      );

      coordinator.updateAssistantMessageContent(
        pair.assistantMsgId,
        pair.assistantMsgIndex,
        '结果是 2。',
      );

      expect(
        coordinator.messages[pair.assistantMsgIndex].content,
        equals('结果是 2。'),
      );

      final updatedEvents =
          emittedEvents.whereType<MessageUpdatedEvent>().toList();
      expect(updatedEvents.length, greaterThanOrEqualTo(2));
      expect(updatedEvents.last.content, equals('结果是 2。'));
    });

    test('4. 多模态图片路径补丁与关联 (updateMessageImagePath)', () {
      final pair = coordinator.appendUserAndPlaceholderMessage('看这张图');
      coordinator.updateMessageImagePath(
        pair.userMsgId,
        '/tmp/test_photo.jpg',
      );

      final userMsg =
          coordinator.messages.firstWhere((m) => m.id == pair.userMsgId);
      expect(userMsg.imagePath, equals('/tmp/test_photo.jpg'));

      final imageUpdateEvent = emittedEvents.firstWhere(
        (e) => e is MessageUpdatedEvent && e.imagePath == '/tmp/test_photo.jpg',
      ) as MessageUpdatedEvent;
      expect(imageUpdateEvent.messageId, equals(pair.userMsgId));
    });

    test('5. 会话创建、切换与事件发射 (startNewSession & switchSession)', () async {
      coordinator.appendUserAndPlaceholderMessage('会话1内容');
      final session1Id = coordinator.currentSessionId;

      // 开启新会话
      await coordinator.startNewSession();
      final session2Id = coordinator.currentSessionId;
      expect(session2Id, isNot(equals(session1Id)));
      expect(coordinator.messages, isEmpty);

      final createdEvent = emittedEvents.firstWhere(
        (e) => e is SessionChangedEvent && e.action == 'created',
      ) as SessionChangedEvent;
      expect(createdEvent.sessionId, equals(session2Id));

      // 切换回会话 1
      final switched = await coordinator.switchSession(session1Id);
      expect(switched, isNotNull);
      expect(switched!.id, equals(session1Id));
      expect(coordinator.currentSessionId, equals(session1Id));

      final switchedEvent = emittedEvents.firstWhere(
        (e) => e is SessionChangedEvent && e.action == 'switched',
      ) as SessionChangedEvent;
      expect(switchedEvent.sessionId, equals(session1Id));
    });

    test('6. 会话重命名、删除与清空 (renameSession, deleteSession, clearAllHistory)', () async {
      coordinator.appendUserAndPlaceholderMessage('会话内容测试');
      final sId = coordinator.currentSessionId;

      await coordinator.renameSession(sId, '新标题-关于计算');
      final renamedEvent = emittedEvents.firstWhere(
        (e) => e is SessionChangedEvent && e.action == 'renamed',
      );
      expect(renamedEvent, isNotNull);

      // 删除会话
      final wasCurrent = await coordinator.deleteSession(sId);
      expect(wasCurrent, isTrue);
      final deletedEvent = emittedEvents.firstWhere(
        (e) => e is SessionChangedEvent && e.action == 'deleted',
      );
      expect(deletedEvent, isNotNull);

      // 清空所有历史
      await coordinator.clearAllHistory();
      final clearedEvent = emittedEvents.firstWhere(
        (e) => e is SessionChangedEvent && e.action == 'cleared',
      );
      expect(clearedEvent, isNotNull);
    });

    test('7. HTML 格式导出契约验证 (exportChatHistoryHtml & exportAllHistoryToHtml)', () async {
      coordinator.appendUserAndPlaceholderMessage('测试导出');
      await coordinator.syncCurrentSession(persist: true);

      final htmlSingle = await coordinator.exportChatHistoryHtml();
      expect(htmlSingle, contains('<!DOCTYPE html>'));
      expect(htmlSingle, contains('<html'));

      final allPath = await coordinator.exportAllHistoryToHtml();
      expect(allPath, endsWith('.html'));
    });
  });
}
