import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 声纹识别与注册处理器：
/// - POST /api/speaker/enroll: 注册主人声纹特征（支持录制新样本或复用最近音频片段）
/// - POST /api/speaker/clear: 清空已注册的主人声纹库
/// - POST /api/speaker/test: 测试声纹相似度评分
class SpeakerHandler extends BaseHandler {
  SpeakerHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.post('/api/speaker/enroll', handleEnroll);
    router.post('/api/speaker/clear', handleClear);
    router.post('/api/speaker/test', handleTest);
  }

  Future<void> handleEnroll(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final bool record = map['record'] == true;
    final double seconds = (map['seconds'] as num?)?.toDouble() ?? 3.5;

    final bool success;
    if (record) {
      success = await driverPort.recordAndEnrollOwnerSpeaker(seconds: seconds);
    } else {
      final audio = driverPort.getRecentAudioSnippet(seconds: seconds);
      success = await driverPort.enrollOwnerSpeaker(samples: audio);
    }
    ctx.sendJson({
      'accepted': success,
      'enrolledCount': driverPort.enrolledSpeakerCount,
      'error': success
          ? null
          : (driverPort.lastEnrollError ??
              '未检测到清晰有效语音或有效片段过短（请对着麦克风连续朗读 2~3 秒）'),
    });
  }

  Future<void> handleClear(RequestContext ctx) async {
    await driverPort.clearOwnerSpeaker();
    ctx.sendJson({
      'accepted': true,
      'enrolledCount': 0,
    });
  }

  Future<void> handleTest(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final bool record = map['record'] == true;
    final double seconds = (map['seconds'] as num?)?.toDouble() ?? 3.0;

    final Map<String, dynamic> res;
    if (record) {
      res = await driverPort.recordAndTestOwnerSpeakerSimilarity(
          seconds: seconds);
    } else {
      final audio = driverPort.getRecentAudioSnippet(seconds: seconds);
      res = await driverPort.testOwnerSpeakerSimilarity(samples: audio);
    }
    ctx.sendJson(res);
  }
}
