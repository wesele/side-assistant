import 'dart:convert';
import 'dart:io';
import '../../controllers/assistant_controller.dart';

class AppDriverServer {
  final AssistantController controller;
  final int port;
  HttpServer? _server;

  AppDriverServer({
    required this.controller,
    this.port = 19823,
  });

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen(_handleRequest);
    } catch (_) {
      // 端口被占用或受限时静默处理，不影响主应用
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest request) async {
    // 允许跨域
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (request.method == 'GET' && path == '/health') {
        _sendJson(request.response, {
          'status': 'ok',
          'app': 'SideAssistant',
          'port': port,
        });
      } else if (request.method == 'GET' && path == '/status') {
        _sendJson(request.response, {
          'status': controller.status.name,
          'statusHint': controller.statusHint,
          'liveTranscript': controller.liveTranscript,
          'currentSessionId': controller.currentSessionId,
          'messageCount': controller.messages.length,
          'isSelfTesting': controller.isSelfTesting,
          'lastMessage': controller.messages.isNotEmpty
              ? controller.messages.last.toMap()
              : null,
        });
      } else if (request.method == 'GET' && path == '/messages') {
        _sendJson(request.response, {
          'messages': controller.messages.map((m) => m.toMap()).toList(),
        });
      } else if (request.method == 'POST' && path == '/simulate') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final text = (map['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          // 异步驱动输入
          controller.simulateUserInput(text);
          _sendJson(request.response, {
            'accepted': true,
            'input': text,
            'currentStatus': controller.status.name,
          });
        } else {
          _sendJson(request.response, {'error': 'text is required'}, status: HttpStatus.badRequest);
        }
      } else if (request.method == 'POST' && path == '/reset') {
        await controller.startNewSession(playVoice: false);
        _sendJson(request.response, {
          'accepted': true,
          'action': 'reset',
          'currentSessionId': controller.currentSessionId,
        });
      } else if (request.method == 'POST' && path == '/toggle-mic') {
        await controller.toggleMicListening();
        _sendJson(request.response, {
          'accepted': true,
          'isMicListening': controller.isMicListening,
          'statusHint': controller.statusHint,
        });
      } else if (request.method == 'POST' && path == '/process-audio') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final filePath = (map['path'] as String?)?.trim() ?? '';
        await controller.processAudioFile(filePath);
        _sendJson(request.response, {
          'accepted': true,
          'path': filePath,
          'lastRecognized': controller.lastRecognizedSpeech,
          'liveTranscript': controller.liveTranscript,
          'status': controller.status.name,
        });
      } else if (request.method == 'POST' && path == '/transcribe') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final filePath = (map['path'] as String?)?.trim() ?? '';
        final isStandby = (map['isStandby'] as bool?) ?? false;
        final text = await controller.asrService.transcribeAudioFile(filePath, isStandbyWakeCheck: isStandby);
        _sendJson(request.response, {
          'accepted': true,
          'path': filePath,
          'recognized': text,
        });
      } else if (request.method == 'POST' && path == '/run-self-test') {
        // 启动后台自检任务
        final report = await controller.runDiagnosticSelfTest();
        _sendJson(request.response, report);
      } else if (request.method == 'GET' && path == '/test-results') {
        _sendJson(request.response, {
          'isSelfTesting': controller.isSelfTesting,
          'logs': controller.selfTestLogs,
        });
      } else {
        _sendJson(request.response, {'error': 'Not found'}, status: HttpStatus.notFound);
      }
    } catch (e) {
      _sendJson(request.response, {'error': e.toString()}, status: HttpStatus.internalServerError);
    }
  }

  void _sendJson(HttpResponse response, Map<String, dynamic> data, {int status = HttpStatus.ok}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }
}
