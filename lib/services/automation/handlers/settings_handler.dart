import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/models/gemini_live_key_pool.dart';
import '../../llm/llm_service.dart';

/// 系统配置与模型管理处理器：
/// - GET /api/settings: 获取当前应用全部配置与声纹样本数
/// - GET /api/gemini-key-pool: 获取 Gemini Live 多 Key 池实时 TPM 与冷却状态
/// - POST /api/settings: 增量合并并持久化应用配置
/// - POST /api/fetch-models: 动态查询远端 OpenAI 兼容端点支持的模型列表
/// - POST /api/test-gemini: 测试 Gemini ASR 在线语音识别联通性
class SettingsHandler extends BaseHandler {
  SettingsHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/api/settings', handleGetSettings);
    router.get('/api/gemini-key-pool', handleGetGeminiKeyPool);
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

  void handleGetGeminiKeyPool(RequestContext ctx) {
    ctx.sendJson({
      'keys': GeminiLiveKeyPool.instance.getPoolStatusMaps(driverPort.settings),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> handleUpdateSettings(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final merged = Map<String, dynamic>.from(driverPort.settings.toMap())
      ..addAll(map);
    if (map.containsKey('geminiApiKeys') && !map.containsKey('geminiApiKey')) {
      final parsed = GeminiApiKeyEntry.normalizeList(map['geminiApiKeys']);
      merged['geminiApiKey'] = parsed.isNotEmpty ? parsed.first.apiKey : '';
    }
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
    var apiKey = (map['apiKey'] as String?)?.trim();
    if ((apiKey == null || apiKey.isEmpty) && map['apiKeys'] != null) {
      final parsed = GeminiApiKeyEntry.normalizeList(map['apiKeys']);
      if (parsed.isNotEmpty) apiKey = parsed.first.apiKey;
    }
    final model = map['model'] as String?;
    final result = await driverPort.testGeminiAsrConnection(
      apiKey: (apiKey == null || apiKey.isEmpty) ? null : apiKey,
      model: model,
    );
    ctx.sendJson({'result': result});
  }
}
