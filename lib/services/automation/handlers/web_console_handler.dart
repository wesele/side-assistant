import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';
import '../web_console_html.dart';

/// Web 控制台页面与导出处理器：
/// - GET / 及 GET /index.html 渲染内置 Web Console 单页应用
/// - GET /api/export-html 导出并下载会话历史 HTML
class WebConsoleHandler extends BaseHandler {
  WebConsoleHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/', handleIndex, requiresAuth: false);
    router.get('/index.html', handleIndex, requiresAuth: false);
    router.get('/api/export-html', handleExportHtml, requiresAuth: true);
  }

  void handleIndex(RequestContext ctx) {
    ctx.sendHtml(buildWebConsoleHtml());
  }

  Future<void> handleExportHtml(RequestContext ctx) async {
    final html = await driverPort.exportChatHistoryHtml();
    ctx.sendHtml(
      html,
      headers: {
        'Content-Disposition':
            'attachment; filename="side_assistant_history.html"',
      },
    );
  }
}
