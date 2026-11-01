import 'dart:io';
import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 会话管理与图片资源处理器：
/// - GET /api/sessions: 获取全部历史会话列表
/// - POST /api/sessions/switch: 切换当前活跃会话
/// - POST /api/sessions/rename: 重命名指定会话标题
/// - POST /api/sessions/delete: 删除指定历史会话
/// - POST /api/sessions/clear: 清空全部历史会话
/// - GET /api/image: 根据 msgId 或 path 查询并输出 JPEG 图片字节
class SessionHandler extends BaseHandler {
  SessionHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/api/sessions', handleListSessions);
    router.post('/api/sessions/switch', handleSwitchSession);
    router.post('/api/sessions/rename', handleRenameSession);
    router.post('/api/sessions/delete', handleDeleteSession);
    router.post('/api/sessions/clear', handleClearSessions);
    router.get('/api/image', handleGetImage);
  }

  void handleListSessions(RequestContext ctx) {
    ctx.sendJson({
      'currentSessionId': driverPort.currentSessionId,
      'sessions': driverPort.sessions.map((s) => s.toMap()).toList(),
    });
  }

  Future<void> handleSwitchSession(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
    await driverPort.switchSession(sessionId);
    ctx.sendJson({
      'accepted': true,
      'currentSessionId': driverPort.currentSessionId,
    });
  }

  Future<void> handleRenameSession(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
    final title = (map['title'] as String?)?.trim() ?? '';
    await driverPort.renameSession(sessionId, title);
    ctx.sendJson({'accepted': true});
  }

  Future<void> handleDeleteSession(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
    await driverPort.deleteSession(sessionId);
    ctx.sendJson({'accepted': true});
  }

  Future<void> handleClearSessions(RequestContext ctx) async {
    await driverPort.clearAllHistory();
    ctx.sendJson({'accepted': true});
  }

  Future<void> handleGetImage(RequestContext ctx) async {
    final msgId = ctx.queryParams['msgId']?.trim() ?? '';
    final directPath = ctx.queryParams['path']?.trim() ?? '';
    String? imgPath;

    if (directPath.isNotEmpty && File(directPath).existsSync()) {
      imgPath = directPath;
    } else if (msgId.isNotEmpty) {
      for (final m in driverPort.messages) {
        if (m.id == msgId && m.imagePath != null) {
          imgPath = m.imagePath;
          break;
        }
      }
      if (imgPath == null) {
        for (final s in driverPort.sessions) {
          for (final m in s.messages) {
            if (m.id == msgId && m.imagePath != null) {
              imgPath = m.imagePath;
              break;
            }
          }
        }
      }
    }

    if (imgPath != null && File(imgPath).existsSync()) {
      final bytes = await File(imgPath).readAsBytes();
      ctx.sendBytes(bytes, contentType: ContentType('image', 'jpeg'));
    } else {
      ctx.sendError('Image not found', status: HttpStatus.notFound);
    }
  }
}
