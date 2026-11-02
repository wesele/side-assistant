import 'dart:typed_data';

import '../models/chat_session.dart';

/// 会话与聊天历史持久化仓库端口 (Chat Repository Port)
///
/// 定义多会话加载、保存、多模态附件转存与 HTML 导出的持久化契约。
abstract interface class ChatRepository {
  Future<List<ChatSession>> loadSessions();
  Future<void> saveSessions(List<ChatSession> sessions);
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  });
  Future<void> deleteSessionImages(ChatSession session);
  Future<void> deleteAllSessionsImages(Iterable<ChatSession> sessions);
  Future<String> buildExportHtml(List<ChatSession> sessions);
  Future<String> exportSessionsToHtmlFile(List<ChatSession> sessions);
}

/// 纯内存会话持久化实现（用于无持久化运行态、测试与安全回退）
class InMemoryChatRepository implements ChatRepository {
  final List<ChatSession> _sessions = [];

  @override
  Future<List<ChatSession>> loadSessions() async => List.unmodifiable(_sessions);

  @override
  Future<void> saveSessions(List<ChatSession> sessions) async {
    _sessions
      ..clear()
      ..addAll(sessions);
  }

  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async =>
      sourcePath;

  @override
  Future<void> deleteSessionImages(ChatSession session) async {}

  @override
  Future<void> deleteAllSessionsImages(Iterable<ChatSession> sessions) async {}

  @override
  Future<String> buildExportHtml(List<ChatSession> sessions) async =>
      '<html><body><h1>SideAssistant Export</h1></body></html>';

  @override
  Future<String> exportSessionsToHtmlFile(List<ChatSession> sessions) async => '';
}

/// 仓库工厂注册表 (SPI 扩展点与 Composition Root 装配入口)
class ChatRepositoryFactoryRegistry {
  static ChatRepository Function()? defaultFactory;
}
