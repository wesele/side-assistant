import 'dart:async';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';

import '../engine_events.dart';
import '../../ports/chat_repository.dart';
import '../../ports/knowledge_port.dart';
import '../../ports/session_message_port.dart';
import '../../../services/storage/chat_history_service.dart';
import '../../../services/storage/session_manager.dart';

export '../../ports/session_message_port.dart'
    show AppendedMessagePair, SessionMessagePort;

/// 会话与历史协调器 (SessionCoordinator)
///
/// 垂直闭环管理多会话生命周期 CRUD、消息增量更新、多模态图片落地与历史记录持久化/HTML 导出。
/// 纯 Dart 实现，无 Flutter UI 或 `dart:ui` 依赖。
class SessionCoordinator implements SessionMessagePort {
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;

  late final SessionManager sessionManager;
  late final ChatRepository chatHistoryService;
  KnowledgePort? lightRagService;

  bool _disposed = false;

  SessionCoordinator({
    required this.emit,
    required this.onNotify,
    SessionManager? sessionManager,
    ChatRepository? chatHistoryService,
    this.lightRagService,
  }) {
    this.chatHistoryService = chatHistoryService ?? ChatHistoryService();
    this.sessionManager = sessionManager ??
        SessionManager(
          chatHistoryService: this.chatHistoryService,
          onStateChanged: () {
            if (!_disposed) {
              emit(SessionChangedEvent(
                this.sessionManager.currentSessionId,
                sessions: this.sessionManager.sessions,
                action: 'updated',
              ));
              onNotify();
            }
          },
        );
  }

  bool get isDisposed => _disposed;

  @override
  String get currentSessionId => sessionManager.currentSessionId;

  @override
  List<ChatMessage> get messages => sessionManager.messages;
  List<ChatMessage> get mutableMessages => sessionManager.mutableMessages;
  List<ChatSession> get sessions => sessionManager.sessions;

  /// 加载历史会话列表
  Future<void> loadChatHistory() async {
    await sessionManager.loadChatHistory();
    if (_disposed) return;
    emit(SessionChangedEvent(
      sessionManager.currentSessionId,
      sessions: sessionManager.sessions,
      action: 'loaded',
    ));
    onNotify();
  }

  /// 切换当前活动会话
  @override
  Future<ChatSession?> switchSession(String sessionId) async {
    if (sessionId == sessionManager.currentSessionId) return null;
    final target = await sessionManager.switchSession(sessionId);
    if (target == null) return null;
    emit(SessionChangedEvent(
      sessionId,
      sessions: sessionManager.sessions,
      action: 'switched',
    ));
    onNotify();
    return target;
  }

  /// 重命名会话标题
  Future<void> renameSession(String sessionId, String newTitle) async {
    await sessionManager.renameSession(sessionId, newTitle);
    emit(SessionChangedEvent(
      sessionManager.currentSessionId,
      sessions: sessionManager.sessions,
      action: 'renamed',
    ));
    onNotify();
  }

  /// 删除指定会话，若为当前会话返回 true
  Future<bool> deleteSession(String sessionId) async {
    final wasCurrent = await sessionManager.deleteSession(sessionId);
    emit(SessionChangedEvent(
      sessionManager.currentSessionId,
      sessions: sessionManager.sessions,
      action: 'deleted',
    ));
    onNotify();
    return wasCurrent;
  }

  /// 清空所有历史会话
  Future<void> clearAllHistory() async {
    await sessionManager.clearAllHistory();
    emit(SessionChangedEvent(
      sessionManager.currentSessionId,
      sessions: sessionManager.sessions,
      action: 'cleared',
    ));
    onNotify();
  }

  /// 开启新会话，自动归档并清空当前临时消息
  @override
  Future<ChatSession?> startNewSession() async {
    ChatSession? finished;
    if (sessionManager.messages.isNotEmpty) {
      finished = await sessionManager.syncCurrentSession(persist: true);
      if (finished != null && lightRagService != null) {
        unawaited(lightRagService!.archiveSession(finished));
      }
    }
    sessionManager.resetSessionId();
    sessionManager.clearCurrentMessages();
    emit(SessionChangedEvent(
      sessionManager.currentSessionId,
      sessions: sessionManager.sessions,
      action: 'created',
    ));
    onNotify();
    return finished;
  }

  /// 同步持久化当前会话
  @override
  Future<ChatSession?> syncCurrentSession({bool persist = true}) async {
    return await sessionManager.syncCurrentSession(persist: persist);
  }

  /// 原子追加用户消息与助手空白占位消息
  @override
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  }) {
    final activeSessionId = sessionManager.currentSessionId;
    final userMsgId = const Uuid().v4();
    final userMsg = ChatMessage(
      id: userMsgId,
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      sessionId: activeSessionId,
      imagePath: imagePath,
    );
    mutableMessages.add(userMsg);
    emit(MessageAppendedEvent(
      userMsg,
      index: mutableMessages.length - 1,
      sessionId: activeSessionId,
    ));

    final assistantMsgId = const Uuid().v4();
    final currentAssistantMsg = ChatMessage(
      id: assistantMsgId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      sessionId: activeSessionId,
    );
    mutableMessages.add(currentAssistantMsg);
    final assistantMsgIndex = mutableMessages.length - 1;
    emit(MessageAppendedEvent(
      currentAssistantMsg,
      index: assistantMsgIndex,
      sessionId: activeSessionId,
    ));
    onNotify();

    return (
      userMsgId: userMsgId,
      assistantMsgId: assistantMsgId,
      assistantMsgIndex: assistantMsgIndex,
    );
  }

  /// 流式增量更新助手消息内容
  @override
  void updateAssistantMessageContent(
    String assistantMsgId,
    int preferredIndex,
    String content, {
    bool isStreaming = false,
  }) {
    int idx = (preferredIndex >= 0 &&
            preferredIndex < mutableMessages.length &&
            mutableMessages[preferredIndex].id == assistantMsgId)
        ? preferredIndex
        : mutableMessages.indexWhere((m) => m.id == assistantMsgId);
    if (idx != -1) {
      final updated = ChatMessage(
        id: assistantMsgId,
        role: 'assistant',
        content: content,
        timestamp: DateTime.now(),
        sessionId: sessionManager.currentSessionId,
      );
      mutableMessages[idx] = updated;
      emit(MessageUpdatedEvent(
        updated,
        messageId: assistantMsgId,
        content: content,
        sessionId: sessionManager.currentSessionId,
      ));
      onNotify();
    }
  }

  /// 更新指定消息的图片路径
  @override
  void updateMessageImagePath(String messageId, String imagePath) {
    final idx = mutableMessages.indexWhere((m) => m.id == messageId);
    if (idx != -1) {
      final old = mutableMessages[idx];
      final updated = ChatMessage(
        id: old.id,
        role: old.role,
        content: old.content,
        timestamp: old.timestamp,
        sessionId: old.sessionId,
        imagePath: imagePath,
      );
      mutableMessages[idx] = updated;
      emit(MessageUpdatedEvent(
        updated,
        messageId: updated.id,
        imagePath: imagePath,
        sessionId: sessionManager.currentSessionId,
      ));
      onNotify();
    }
  }

  /// 持久化多模态图片至应用数据目录
  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async {
    return await chatHistoryService.persistImage(
      sessionId: sessionId,
      messageId: messageId,
      sourcePath: sourcePath,
      imageBytes: imageBytes,
    );
  }

  /// 导出当前全量会话为 HTML
  Future<String> exportChatHistoryHtml() async {
    return await chatHistoryService.buildExportHtml(sessions);
  }

  /// 导出所有会话为 HTML 格式字符串
  Future<String> exportAllHistoryToHtml() async {
    return sessionManager.exportAllHistoryToHtml();
  }

  /// 归档会话到 LightRAG
  Future<void> archiveToLightRag(ChatSession session) async {
    if (lightRagService != null) {
      await lightRagService!.archiveSession(session);
    }
  }

  /// 更新 LightRagService 引用
  @override
  void updateLightRagService(KnowledgePort? service) {
    lightRagService = service;
  }

  /// 销毁协调器
  void dispose() {
    _disposed = true;
  }
}
