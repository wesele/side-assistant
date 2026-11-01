import 'dart:async';
import 'dart:io';
import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 对话与交互处理器：
/// - POST /simulate: 模拟外部文本输入并触发完整的智能体决策管线
/// - POST /api/chat: 发送用户文本消息（支持 speak 参数指定是否语音回复）
/// - POST /api/capture-and-ask: 现场摄像头拍照并提交多模态大模型问答
/// - POST /reset: 重置并新建会话（无语音播报）
/// - GET /messages: 获取当前活跃会话的全部消息列表
class ChatHandler extends BaseHandler {
  ChatHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.post('/simulate', handleSimulate);
    router.post('/api/chat', handleChat);
    router.post('/api/capture-and-ask', handleCaptureAndAsk);
    router.post('/reset', handleReset);
    router.get('/messages', handleMessages);
  }

  Future<void> handleSimulate(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final text = (map['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      ctx.sendError('text is required', status: HttpStatus.badRequest);
      return;
    }
    unawaited(driverPort.simulateUserInput(text));
    ctx.sendJson({
      'accepted': true,
      'input': text,
      'currentStatus': driverPort.status.name,
    });
  }

  Future<void> handleChat(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final text = (map['text'] as String?)?.trim() ?? '';
    final speak = (map['speak'] as bool?) ?? false;
    if (text.isEmpty) {
      ctx.sendError('text is required', status: HttpStatus.badRequest);
      return;
    }
    if (speak) {
      unawaited(driverPort.sendDirectUserMessage(text));
    } else {
      unawaited(driverPort.sendTextMessage(text));
    }
    ctx.sendJson({
      'accepted': true,
      'text': text,
      'speak': speak,
    });
  }

  Future<void> handleCaptureAndAsk(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final question = (map['question'] as String?)?.trim() ?? '这是什么，介绍一下';
    unawaited(driverPort.captureAndAskAboutScene(question: question));
    ctx.sendJson({
      'accepted': true,
      'question': question,
    });
  }

  Future<void> handleReset(RequestContext ctx) async {
    await driverPort.startNewSession(playVoice: false);
    ctx.sendJson({
      'accepted': true,
      'action': 'reset',
      'currentSessionId': driverPort.currentSessionId,
    });
  }

  void handleMessages(RequestContext ctx) {
    ctx.sendJson({
      'messages': driverPort.messages.map((m) => m.toMap()).toList(),
    });
  }
}
