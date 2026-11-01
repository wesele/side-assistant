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
