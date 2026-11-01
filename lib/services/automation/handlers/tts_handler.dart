import 'dart:async';
import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 语音合成与播报处理器：
/// - POST /api/stop-speaking: 即时打断并停止正在播放的语音
/// - POST /api/speak-text: 立即朗读指定文本（非阻塞）
/// - POST /api/preview-voice: 试听指定音色与样例文本
class TtsHandler extends BaseHandler {
  TtsHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.post('/api/stop-speaking', handleStopSpeaking);
    router.post('/api/speak-text', handleSpeakText);
    router.post('/api/preview-voice', handlePreviewVoice);
  }

  Future<void> handleStopSpeaking(RequestContext ctx) async {
    await driverPort.stopSpeaking();
    ctx.sendJson({'accepted': true});
  }

  Future<void> handleSpeakText(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final text = (map['text'] as String?)?.trim() ?? '';
    if (text.isNotEmpty) {
      unawaited(driverPort.speakImmediate(text));
    }
    ctx.sendJson({'accepted': true});
  }

  Future<void> handlePreviewVoice(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final voice =
        (map['voice'] as String?)?.trim() ?? driverPort.settings.edgeVoice;
    final text = (map['text'] as String?)?.trim() ??
        '你好，我是随身语音管家，很高兴为你服务。';
    unawaited(driverPort.previewVoice(voice: voice, text: text));
    ctx.sendJson({'accepted': true});
  }
}
