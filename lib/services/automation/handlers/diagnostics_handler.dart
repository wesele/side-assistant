import 'dart:convert';
import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 硬件诊断与相机测试处理器：
/// - POST /run-self-test: 触发全链路系统自检脚本
/// - GET /test-results: 获取当前自检状态与执行日志
/// - POST /api/test-camera: 测试摄像头即时拍照并返回 Base64 缩略图
class DiagnosticsHandler extends BaseHandler {
  DiagnosticsHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.post('/run-self-test', handleRunSelfTest);
    router.get('/test-results', handleTestResults);
    router.post('/api/test-camera', handleTestCamera);
  }

  Future<void> handleRunSelfTest(RequestContext ctx) async {
    final report = await driverPort.runDiagnosticSelfTest();
    ctx.sendJson(report);
  }

  void handleTestResults(RequestContext ctx) {
    ctx.sendJson({
      'isSelfTesting': driverPort.isSelfTesting,
      'logs': driverPort.selfTestLogs,
    });
  }

  Future<void> handleTestCamera(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final dev = (map['device'] as String?)?.trim();
    if (dev != null) {
      driverPort.settings.linuxCameraDevice = dev;
    }
    try {
      final shot = await driverPort.capturePhotoDirect();
      ctx.sendJson({
        'accepted': true,
        'byteLength': shot.imageBytes.length,
        'filePath': shot.filePath,
        'isSimulated': shot.isSimulated,
        'base64': base64Encode(shot.imageBytes),
      });
    } catch (e) {
      ctx.sendJson({'error': '$e'});
    }
  }
}
