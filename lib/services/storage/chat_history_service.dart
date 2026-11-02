import '../../core/ports/chat_repository.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/models/chat_session.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import '../../core/platform/system_file_launcher.dart';

class ChatHistoryService implements ChatRepository {
  static const String _storageKey = 'chat_history_sessions_v1';
  static const String _imagesDirName = 'chat_images';

  final Directory? customImagesDir;
  final Directory? customExportDir;

  ChatHistoryService({
    this.customImagesDir,
    this.customExportDir,
  });

  static void registerDefault() {
    ChatRepositoryFactoryRegistry.defaultFactory = () => ChatHistoryService();
  }

  @override
  Future<List<ChatSession>> loadSessions() async {
    try {
      final rawJson = await StorageBridge.readPreferenceString(_storageKey);
      if (rawJson == null || rawJson.isEmpty) {
        return [];
      }
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) return [];
      final sessions = <ChatSession>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          try {
            final session = ChatSession.fromMap(item);
            if (session.messages.isNotEmpty) {
              sessions.add(session);
            }
          } catch (e) {
            debugPrint('[ChatHistoryService] 解析单条会话失败: $e');
          }
        }
      }
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return sessions;
    } catch (e) {
      debugPrint('[ChatHistoryService] 加载历史会话失败: $e');
      return [];
    }
  }

  @override
  Future<void> saveSessions(List<ChatSession> sessions) async {
    try {
      final nonEmpty =
          sessions.where((s) => s.messages.isNotEmpty).toList(growable: false);
      final encoded = jsonEncode(nonEmpty.map((s) => s.toMap()).toList());
      await StorageBridge.writePreferenceString(_storageKey, encoded);
    } catch (e) {
      debugPrint('[ChatHistoryService] 保存历史会话失败: $e');
    }
  }

  Future<Directory?> _resolveImagesDirectory() async {
    if (customImagesDir != null) {
      if (!customImagesDir!.existsSync()) {
        customImagesDir!.createSync(recursive: true);
      }
      return customImagesDir;
    }
    try {
      final supportDir = await StorageBridge.getAppSupportDirectory();
      final imagesDir = Directory(p.join(supportDir.path, _imagesDirName));
      if (!imagesDir.existsSync()) {
        imagesDir.createSync(recursive: true);
      }
      return imagesDir;
    } catch (e) {
      // 单元测试或平台不支持 path_provider 时降级保留原路径
      debugPrint('[ChatHistoryService] 获取持久化图片目录失败，保留原路径: $e');
      return null;
    }
  }

  /// 将对话中抓拍的图片转存到应用持久化目录，避免系统清理临时目录导致历史对话图片丢失
  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async {
    final hasPath = sourcePath != null && sourcePath.isNotEmpty;
    final hasBytes = imageBytes != null && imageBytes.isNotEmpty;
    if (!hasPath && !hasBytes) return sourcePath;

    final imagesDir = await _resolveImagesDirectory();
    if (imagesDir == null) {
      return sourcePath;
    }

    try {
      final ext = hasPath && p.extension(sourcePath).isNotEmpty
          ? p.extension(sourcePath)
          : '.jpg';
      final targetPath = p.join(imagesDir.path, '${sessionId}_$messageId$ext');
      if (hasPath && p.equals(sourcePath, targetPath)) {
        return targetPath;
      }

      final targetFile = File(targetPath);
      if (hasBytes) {
        targetFile.writeAsBytesSync(imageBytes, flush: true);
        return targetFile.path;
      }

      if (hasPath) {
        final srcFile = File(sourcePath);
        if (srcFile.existsSync()) {
          srcFile.copySync(targetPath);
          return targetFile.path;
        }
      }
    } catch (e) {
      debugPrint('[ChatHistoryService] 转存对话图片失败: $e');
    }
    return sourcePath;
  }

  /// 删除指定会话关联的持久化图片文件
  @override
  Future<void> deleteSessionImages(ChatSession session) async {
    for (final msg in session.messages) {
      final imgPath = msg.imagePath;
      if (imgPath == null || imgPath.isEmpty) continue;
      try {
        final file = File(imgPath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (e) {
        debugPrint('[ChatHistoryService] 清理对话图片失败 ($imgPath): $e');
      }
    }
  }

  /// 删除多个会话关联的所有图片文件
  @override
  Future<void> deleteAllSessionsImages(Iterable<ChatSession> sessions) async {
    for (final session in sessions) {
      await deleteSessionImages(session);
    }
  }

  static String _escapeHtml(String text) {
    return const HtmlEscape(HtmlEscapeMode.element)
        .convert(text)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _formatDateTime(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  static String _mimeTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  /// 将全部历史对话（含本地图片 Base64 内嵌）编译为单个自包含 HTML 字符串
  @override
  Future<String> buildExportHtml(List<ChatSession> sessions) async {
    final nowStr = _formatDateTime(DateTime.now());
    final navItems = StringBuffer();
    final sessionCards = StringBuffer();

    for (var i = 0; i < sessions.length; i++) {
      final session = sessions[i];
      final safeTitle = _escapeHtml(session.title);
      final updatedStr = _formatDateTime(session.updatedAt);
      final anchorId = 'session-${i + 1}';

      navItems.writeln(
        '<a class="nav-item" href="#$anchorId">'
        '<div class="nav-title">$safeTitle</div>'
        '<div class="nav-meta">$updatedStr · ${session.messages.length} 条消息</div>'
        '</a>',
      );

      sessionCards.writeln('<section class="session-card" id="$anchorId">');
      sessionCards.writeln(
        '<header class="session-header">'
        '<h2>$safeTitle</h2>'
        '<span class="session-time">更新于 $updatedStr</span>'
        '</header>',
      );
      sessionCards.writeln('<div class="message-list">');

      for (final msg in session.messages) {
        final isUser = msg.role == 'user';
        final roleClass = isUser ? 'msg-user' : 'msg-assistant';
        final roleLabel = isUser ? '你' : '助理';
        final msgTime = _formatDateTime(msg.timestamp);
        final safeContent = _escapeHtml(msg.content).replaceAll('\n', '<br>');

        String imageHtml = '';
        if (msg.imagePath != null && msg.imagePath!.isNotEmpty) {
          try {
            final imgFile = File(msg.imagePath!);
            if (imgFile.existsSync()) {
              final bytes = imgFile.readAsBytesSync();
              final b64 = base64Encode(bytes);
              final mime = _mimeTypeForPath(msg.imagePath!);
              imageHtml = '<div class="msg-image-wrap">'
                  '<img class="msg-image" src="data:$mime;base64,$b64" alt="对话抓拍图片" onclick="openLightbox(this.src)" title="点击放大查看" />'
                  '</div>';
            }
          } catch (e) {
            debugPrint(
                '[ChatHistoryService] 导出内嵌图片读取失败 (${msg.imagePath}): $e');
          }
        }

        sessionCards.writeln(
          '<div class="msg-row $roleClass">'
          '<div class="msg-bubble">'
          '<div class="msg-meta"><span class="msg-role">$roleLabel</span><span class="msg-time">$msgTime</span></div>'
          '$imageHtml'
          '<div class="msg-content">$safeContent</div>'
          '</div>'
          '</div>',
        );
      }

      sessionCards.writeln('</div></section>');
    }

    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>对话历史导出 ($nowStr)</title>
  <style>
    :root {
      --bg: #f5f7f9;
      --card: #ffffff;
      --primary: #00796b;
      --user-bg: #e0f2f1;
      --user-text: #004d40;
      --bot-bg: #f1f3f5;
      --bot-text: #212529;
      --muted: #6c757d;
      --border: #dee2e6;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif;
      background: var(--bg);
      color: #212529;
      display: flex;
      min-height: 100vh;
    }
    .sidebar {
      width: 280px;
      background: var(--card);
      border-right: 1px solid var(--border);
      padding: 16px;
      position: sticky;
      top: 0;
      height: 100vh;
      overflow-y: auto;
      flex-shrink: 0;
    }
    .sidebar h1 {
      font-size: 16px;
      margin: 0 0 4px 0;
      color: var(--primary);
    }
    .sidebar .export-info {
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 12px;
      padding-bottom: 12px;
      border-bottom: 1px solid var(--border);
    }
    .nav-item {
      display: block;
      text-decoration: none;
      color: inherit;
      padding: 8px 10px;
      border-radius: 8px;
      margin-bottom: 4px;
      transition: background 0.15s;
    }
    .nav-item:hover { background: #edf2f4; }
    .nav-title {
      font-size: 13px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .nav-meta {
      font-size: 11px;
      color: var(--muted);
      margin-top: 2px;
    }
    .main {
      flex: 1;
      max-width: 900px;
      margin: 0 auto;
      padding: 24px 20px 64px 20px;
    }
    .session-card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 20px;
      margin-bottom: 24px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.04);
    }
    .session-header {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      border-bottom: 1px solid var(--border);
      padding-bottom: 12px;
      margin-bottom: 16px;
      gap: 12px;
    }
    .session-header h2 {
      margin: 0;
      font-size: 17px;
      color: #111;
    }
    .session-time {
      font-size: 12px;
      color: var(--muted);
      white-space: nowrap;
    }
    .msg-row {
      display: flex;
      margin-bottom: 12px;
    }
    .msg-user { justify-content: flex-end; }
    .msg-assistant { justify-content: flex-start; }
    .msg-bubble {
      max-width: 78%;
      padding: 10px 14px;
      border-radius: 14px;
      line-height: 1.55;
      font-size: 14px;
      word-break: break-word;
    }
    .msg-user .msg-bubble {
      background: var(--user-bg);
      color: var(--user-text);
      border-bottom-right-radius: 4px;
    }
    .msg-assistant .msg-bubble {
      background: var(--bot-bg);
      color: var(--bot-text);
      border-bottom-left-radius: 4px;
    }
    .msg-meta {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      font-size: 11px;
      opacity: 0.75;
      margin-bottom: 4px;
      font-weight: 600;
    }
    .msg-image-wrap { margin: 6px 0; }
    .msg-image {
      max-width: 260px;
      max-height: 200px;
      border-radius: 10px;
      cursor: zoom-in;
      display: block;
      object-fit: cover;
    }
    #lightbox {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.86);
      z-index: 9999;
      align-items: center;
      justify-content: center;
      padding: 20px;
      cursor: zoom-out;
    }
    #lightbox img {
      max-width: 95vw;
      max-height: 92vh;
      border-radius: 8px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    }
    @media (max-width: 720px) {
      body { flex-direction: column; }
      .sidebar {
        width: 100%;
        height: auto;
        max-height: 240px;
        position: static;
        border-right: none;
        border-bottom: 1px solid var(--border);
      }
      .msg-bubble { max-width: 90%; }
    }
  </style>
</head>
<body>
  <aside class="sidebar">
    <h1>对话历史归档</h1>
    <div class="export-info">共 ${sessions.length} 个会话 · 导出于 $nowStr</div>
    $navItems
  </aside>
  <main class="main">
    $sessionCards
  </main>
  <div id="lightbox" onclick="this.style.display='none'">
    <img id="lightbox-img" src="" alt="预览大图" />
  </div>
  <script>
    function openLightbox(src) {
      var box = document.getElementById('lightbox');
      var img = document.getElementById('lightbox-img');
      img.src = src;
      box.style.display = 'flex';
    }
  </script>
</body>
</html>''';
  }

  /// 将全部历史对话导出为单个 HTML 文件并调用系统保存/打开或分享面板，返回保存路径
  @override
  Future<String> exportSessionsToHtmlFile(List<ChatSession> sessions) async {
    final html = await buildExportHtml(sessions);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final fileName = 'chat_history_$stamp.html';

    return SystemFileLauncher.saveAndLaunchHtml(
      fileName: fileName,
      htmlContent: html,
      customOutputDir: customExportDir,
    );
  }
}
