import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/chat_session.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/ports/chat_repository.dart';
import 'chat_history_service.dart';

/// 专门负责聊天会话与消息历史管理的领域服务
class SessionManager {
  final ChatRepository chatHistoryService;
  final VoidCallback? onStateChanged;

  String _currentSessionId = const Uuid().v4();
  final List<ChatMessage> _messages = [];
  final List<ChatSession> _sessions = [];

  SessionManager({
    ChatRepository? chatHistoryService,
    this.onStateChanged,
  }) : chatHistoryService = chatHistoryService ?? ChatHistoryService();

  String get currentSessionId => _currentSessionId;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ChatSession> get sessions => List.unmodifiable(_sessions);

  /// 直接访问内部消息列表（供流式拼接或追加）
  List<ChatMessage> get mutableMessages => _messages;

  /// 加载本地持久化的历史会话列表
  Future<void> loadChatHistory() async {
    final loaded = await chatHistoryService.loadSessions();

    final currentMap = <String, ChatSession>{
      for (final s in _sessions) s.id: s,
    };
    for (final s in loaded) {
      currentMap.putIfAbsent(s.id, () => s);
    }
    _sessions
      ..clear()
      ..addAll(currentMap.values);
    _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    onStateChanged?.call();
  }

  /// 将当前会话状态同步进 `_sessions` 列表并按需写入持久化存储
  Future<ChatSession?> syncCurrentSession({bool persist = true}) async {
    if (_messages.isEmpty) return null;

    final now = DateTime.now();
    final existingIdx = _sessions.indexWhere((s) => s.id == _currentSessionId);
    final snapshotMessages = List<ChatMessage>.from(_messages);

    ChatSession session;
    if (existingIdx != -1) {
      final existing = _sessions[existingIdx];
      session = existing.copyWith(
        updatedAt: now,
        messages: snapshotMessages,
      );
      _sessions.removeAt(existingIdx);
      _sessions.insert(0, session);
    } else {
      final firstUserMsg = snapshotMessages.firstWhere(
        (m) => m.role == 'user' && m.content.trim().isNotEmpty,
        orElse: () => snapshotMessages.first,
      );
      final title = ChatSession.generateDefaultTitle(firstUserMsg.content);
      session = ChatSession(
        id: _currentSessionId,
        title: title,
        createdAt: snapshotMessages.first.timestamp,
        updatedAt: now,
        messages: snapshotMessages,
      );
      _sessions.insert(0, session);
    }

    if (persist) {
      await chatHistoryService.saveSessions(_sessions);
    }
    return session;
  }

  /// 恢复指定历史会话，返回目标会话以便上层做提示与重置
  Future<ChatSession?> switchSession(String sessionId) async {
    if (sessionId == _currentSessionId) return null;
    final targetIdx = _sessions.indexWhere((s) => s.id == sessionId);
    if (targetIdx == -1) return null;

    if (_messages.isNotEmpty) {
      await syncCurrentSession(persist: true);
    }

    final target = _sessions.firstWhere((s) => s.id == sessionId);
    _currentSessionId = target.id;
    _messages
      ..clear()
      ..addAll(target.messages);
    onStateChanged?.call();
    return target;
  }

  /// 重命名会话
  Future<void> renameSession(String sessionId, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx == -1) return;

    _sessions[idx] = _sessions[idx].copyWith(title: trimmed);
    onStateChanged?.call();
    await chatHistoryService.saveSessions(_sessions);
  }

  /// 删除单条历史对话并清理关联图片
  Future<bool> deleteSession(String sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    ChatSession? removed;
    if (idx != -1) {
      removed = _sessions.removeAt(idx);
    }

    if (removed != null) {
      await chatHistoryService.deleteSessionImages(removed);
      await chatHistoryService.saveSessions(_sessions);
    }

    final isCurrent = (sessionId == _currentSessionId);
    if (isCurrent) {
      _messages.clear();
      resetSessionId();
    }
    onStateChanged?.call();
    return isCurrent;
  }

  /// 清空所有历史对话及关联图片
  Future<void> clearAllHistory() async {
    final toDelete = List<ChatSession>.from(_sessions);
    _sessions.clear();
    _messages.clear();
    resetSessionId();
    await chatHistoryService.deleteAllSessionsImages(toDelete);
    await chatHistoryService.saveSessions(_sessions);
    onStateChanged?.call();
  }

  /// 导出全部历史为 HTML 文件
  Future<String> exportAllHistoryToHtml() async {
    if (_messages.isNotEmpty) {
      await syncCurrentSession(persist: true);
    }
    return chatHistoryService.exportSessionsToHtmlFile(_sessions);
  }

  /// 重置并生成全新的当前会话 ID
  String resetSessionId() {
    _currentSessionId = const Uuid().v4();
    return _currentSessionId;
  }

  /// 清空当前活动会话的消息上下文
  void clearCurrentMessages() {
    _messages.clear();
    onStateChanged?.call();
  }

  /// 向当前会话追加一条消息
  void addMessage(ChatMessage message) {
    _messages.add(message);
    onStateChanged?.call();
  }
}
