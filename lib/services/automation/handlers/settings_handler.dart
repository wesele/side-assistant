import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';
import '../../../core/models/app_settings.dart';
import '../../llm/llm_service.dart';

/// 系统配置与模型管理处理器：
/// - GET /api/settings: 获取当前应用全部配置与声纹样本数
/// - POST /api/settings: 增量合并并持久化应用配置
/// - POST /api/fetch-models: 动态查询远端 OpenAI 兼容端点支持的模型列表
/// - POST /api/test-gemini: 测试 Gemini ASR 在线语音识别联通性
class SettingsHandler extends BaseHandler {
  SettingsHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/api/settings', handleGetSettings);
    router.post('/api/settings', handleUpdateSettings);
    router.post('/api/fetch-models', handleFetchModels);
    router.post('/api/test-gemini', handleTestGemini);
  }

  void handleGetSettings(RequestContext ctx) {
    ctx.sendJson({
      'settings': driverPort.settings.toMap(),
      'speakerEnrolledCount': driverPort.enrolledSpeakerCount,
      'speakerStoredCount': driverPort.settings.ownerSpeakerEmbeddings.length,
      'speakerModelLabel': driverPort.speakerModelLabel,
    });
  }

  Future<void> handleUpdateSettings(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final merged = Map<String, dynamic>.from(driverPort.settings.toMap())
      ..addAll(map);
    final newSettings = AppSettings.fromMap(merged);
    await driverPort.updateSettings(newSettings);
    ctx.sendJson({
      'accepted': true,
      'settings': driverPort.settings.toMap(),
    });
  }

  Future<void> handleFetchModels(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final baseUrl = (map['baseUrl'] as String?)?.trim() ??
        driverPort.settings.openAiBaseUrl;
    final apiKey =
        (map['apiKey'] as String?)?.trim() ?? driverPort.settings.openAiApiKey;
    try {
      final models = await LlmService.fetchAvailableModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
      if (models.isNotEmpty) {
        driverPort.settings.cachedAvailableModels = models;
        await driverPort.settings.save();
      }
      ctx.sendJson({'models': models});
    } catch (e) {
      ctx.sendJson({'models': const [], 'error': '$e'});
    }
  }

  Future<void> handleTestGemini(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final apiKey = map['apiKey'] as String?;
    final model = map['model'] as String?;
    final result = await driverPort.testGeminiAsrConnection(
      apiKey: apiKey,
      model: model,
    );
    ctx.sendJson({'result': result});
  }
}
