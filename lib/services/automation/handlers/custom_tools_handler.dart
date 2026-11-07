import 'dart:io';

import '../../llm/tools/custom_tool_manager.dart';
import '../http_router.dart';
import '../request_context.dart';
import 'base_handler.dart';

/// 自定义持久化工具处理器 (CustomToolsHandler)
/// - GET /api/custom-tools: 获取所有已安装的持久化工具清单
/// - POST /api/custom-tools/delete: 删除指定名称的自定义工具
/// - DELETE /api/custom-tools/:name: 删除指定名称的自定义工具
class CustomToolsHandler extends BaseHandler {
  final CustomToolManager _toolManager;

  CustomToolsHandler(
    super.driverPort, {
    CustomToolManager? toolManager,
  }) : _toolManager = toolManager ?? CustomToolManager.instance;

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/api/custom-tools', handleListTools);
    router.post('/api/custom-tools/delete', handleDeleteToolPost);
    router.delete('/api/custom-tools/:name', handleDeleteToolParam);
  }

  void handleListTools(RequestContext ctx) {
    final tools = _toolManager.listToolsSync().map((t) => t.toMap()).toList();
    ctx.sendJson({'tools': tools});
  }

  Future<void> handleDeleteToolPost(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final name = (map['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      ctx.sendError('工具名称不能为空', status: HttpStatus.badRequest);
      return;
    }

    final deleted = _toolManager.deleteTool(name);
    final tools = _toolManager.listToolsSync().map((t) => t.toMap()).toList();
    ctx.sendJson({
      'deleted': deleted,
      'name': name,
      'tools': tools,
    });
  }

  void handleDeleteToolParam(RequestContext ctx) {
    final name = (ctx.params['name'] ?? ctx.pathParams['name'] ?? '').trim();
    if (name.isEmpty) {
      ctx.sendError('工具名称不能为空', status: HttpStatus.badRequest);
      return;
    }

    final deleted = _toolManager.deleteTool(name);
    final tools = _toolManager.listToolsSync().map((t) => t.toMap()).toList();
    ctx.sendJson({
      'deleted': deleted,
      'name': name,
      'tools': tools,
    });
  }
}
