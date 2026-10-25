import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../controllers/assistant_controller.dart';
import '../../core/models/app_settings.dart';
import '../linux/linux_hardware_service.dart';
import '../llm/llm_service.dart';
import '../speech/audio_input_device_service.dart';
import 'web_console_html.dart';

class AppDriverServer {
  final AssistantController controller;
  final int port;
  final InternetAddress? bindAddress;
  HttpServer? _server;
  final Set<HttpResponse> _sseClients = <HttpResponse>{};
  bool _listenerAttached = false;

  AppDriverServer({
    required this.controller,
    this.port = 19823,
    this.bindAddress,
  });

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    try {
      final addr = bindAddress ??
          (Platform.isLinux
              ? InternetAddress.anyIPv4
              : InternetAddress.loopbackIPv4);
      _server = await HttpServer.bind(addr, port);
      if (!_listenerAttached) {
        controller.addListener(_broadcastSseState);
        _listenerAttached = true;
      }
      _server!.listen(_handleRequest);
    } catch (_) {
      // 端口被占用或受限时静默处理，不影响主应用
    }
  }

  Future<void> stop() async {
    if (_listenerAttached) {
      controller.removeListener(_broadcastSseState);
      _listenerAttached = false;
    }
    for (final client in _sseClients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _sseClients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Map<String, dynamic> _buildFullStateMap() {
    return {
      'platform': Platform.isLinux
          ? 'Linux Server'
          : (Platform.isWindows ? 'Windows' : Platform.operatingSystem),
      'status': controller.status.name,
      'statusHint': controller.statusHint,
      'liveTranscript': controller.liveTranscript,
      'displayTranscript': controller.displayTranscript,
      'lastRecognizedSpeech': controller.lastRecognizedSpeech,
      'isWakeWordMatched': controller.isWakeWordMatched,
      'isMicListening': controller.isMicListening,
      'isManualRecording': controller.isManualRecording,
      'isQuickCapturing': controller.isQuickCapturing,
      'micLevel': controller.micLevel,
      'micDbfs': controller.micDbfs,
      'vadDetected': controller.vadDetected,
      'isMicTesting': controller.isMicTesting,
      'micTestText': controller.micTestText,
      'micTestHistory': controller.micTestHistory,
      'playbackVolume': controller.settings.playbackVolume,
      'startWords': controller.settings.startWords,
      'endWords': controller.settings.endWords,
      'resetWords': controller.settings.resetWords,
      'currentSessionId': controller.currentSessionId,
      'messageCount': controller.messages.length,
      'isSelfTesting': controller.isSelfTesting,
      'selfTestLogs': controller.selfTestLogs,
      'audioInputDevice': controller.activeAudioInputDeviceLabel,
      'messages': controller.messages.map((m) => m.toMap()).toList(),
      'sessions': controller.sessions
          .map((s) => {
                'id': s.id,
                'title': s.title,
                'createdAt': s.createdAt.toIso8601String(),
                'updatedAt': s.updatedAt.toIso8601String(),
                'messageCount': s.messages.length,
              })
          .toList(),
      'lastMessage': controller.messages.isNotEmpty
          ? controller.messages.last.toMap()
          : null,
    };
  }

  void _broadcastSseState() {
    if (_sseClients.isEmpty) return;
    final payload = 'data: ${jsonEncode(_buildFullStateMap())}\n\n';
    final dead = <HttpResponse>[];
    for (final res in _sseClients) {
      try {
        res.write(payload);
      } catch (_) {
        dead.add(res);
      }
    }
    for (final d in dead) {
      _sseClients.remove(d);
    }
  }

  bool _checkAuthorized(HttpRequest request) {
    final requiredPwd = controller.settings.webAccessPassword.trim();
    if (requiredPwd.isEmpty) return true;

    final headerPwd = request.headers.value('x-access-password')?.trim() ?? '';
    if (headerPwd == requiredPwd) return true;

    final authHeader = request.headers.value('authorization')?.trim() ?? '';
    if (authHeader.startsWith('Bearer ') &&
        authHeader.substring(7).trim() == requiredPwd) {
      return true;
    }

    final queryToken = request.uri.queryParameters['token']?.trim() ?? '';
    if (queryToken == requiredPwd) return true;

    return false;
  }

  void _handleRequest(HttpRequest request) async {
    // 允许跨域
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers
        .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-Access-Password',
    );

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      // 1. Web Console HTML 首页与健康检查免鉴权
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.write(buildWebConsoleHtml());
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path == '/health') {
        _sendJson(request.response, {
          'status': 'ok',
          'app': 'SideAssistant',
          'platform': Platform.operatingSystem,
          'port': port,
        });
        return;
      }

      // 2. 密码校验（若设置了 webAccessPassword）
      if (!_checkAuthorized(request)) {
        _sendJson(
          request.response,
          {'error': 'Unauthorized'},
          status: HttpStatus.unauthorized,
        );
        return;
      }

      // 3. SSE 实时事件流
      if (request.method == 'GET' && path == '/api/events') {
        final response = request.response;
        response.statusCode = HttpStatus.ok;
        response.bufferOutput = false;
        response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
        response.headers.set('Cache-Control', 'no-cache');
        response.headers.set('Connection', 'keep-alive');
        response.write('data: ${jsonEncode(_buildFullStateMap())}\n\n');
        _sseClients.add(response);
        response.done.whenComplete(() {
          _sseClients.remove(response);
        });
        return;
      }

      if (request.method == 'GET' && path == '/api/state') {
        _sendJson(request.response, _buildFullStateMap());
      } else if (request.method == 'GET' && path == '/status') {
        _sendJson(request.response, {
          'status': controller.status.name,
          'statusHint': controller.statusHint,
          'liveTranscript': controller.liveTranscript,
          'currentSessionId': controller.currentSessionId,
          'messageCount': controller.messages.length,
          'isSelfTesting': controller.isSelfTesting,
          'audioInputDevice': controller.activeAudioInputDeviceLabel,
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
          unawaited(controller.simulateUserInput(text));
          _sendJson(request.response, {
            'accepted': true,
            'input': text,
            'currentStatus': controller.status.name,
          });
        } else {
          _sendJson(
            request.response,
            {'error': 'text is required'},
            status: HttpStatus.badRequest,
          );
        }
      } else if (request.method == 'POST' && path == '/api/chat') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final text = (map['text'] as String?)?.trim() ?? '';
        final speak = (map['speak'] as bool?) ?? false;
        if (text.isEmpty) {
          _sendJson(
            request.response,
            {'error': 'text is required'},
            status: HttpStatus.badRequest,
          );
          return;
        }
        if (speak) {
          unawaited(controller.sendDirectUserMessage(text));
        } else {
          unawaited(controller.sendTextMessage(text));
        }
        _sendJson(request.response, {
          'accepted': true,
          'text': text,
          'speak': speak,
        });
      } else if (request.method == 'POST' && path == '/api/capture-and-ask') {
        final bodyStr = await utf8.decodeStream(request);
        final map = bodyStr.trim().isNotEmpty
            ? (jsonDecode(bodyStr) as Map<String, dynamic>)
            : <String, dynamic>{};
        final question =
            (map['question'] as String?)?.trim() ?? '这是什么，介绍一下';
        unawaited(controller.captureAndAskAboutScene(question: question));
        _sendJson(request.response, {
          'accepted': true,
          'question': question,
        });
      } else if (request.method == 'POST' &&
          path == '/api/manual-record/start') {
        await controller.startManualRecording();
        _sendJson(request.response, {
          'accepted': true,
          'isManualRecording': controller.isManualRecording,
        });
      } else if (request.method == 'POST' &&
          path == '/api/manual-record/stop') {
        await controller.stopManualRecording();
        _sendJson(request.response, {
          'accepted': true,
          'isManualRecording': controller.isManualRecording,
        });
      } else if (request.method == 'POST' && path == '/api/stop-speaking') {
        await controller.ttsService.stop();
        _sendJson(request.response, {'accepted': true});
      } else if (request.method == 'POST' && path == '/api/speak-text') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final text = (map['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          unawaited(controller.ttsService.speakImmediate(text));
        }
        _sendJson(request.response, {'accepted': true});
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
      } else if (request.method == 'GET' && path == '/api/sessions') {
        _sendJson(request.response, {
          'currentSessionId': controller.currentSessionId,
          'sessions': controller.sessions.map((s) => s.toMap()).toList(),
        });
      } else if (request.method == 'POST' && path == '/api/sessions/switch') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
        await controller.switchSession(sessionId);
        _sendJson(request.response, {
          'accepted': true,
          'currentSessionId': controller.currentSessionId,
        });
      } else if (request.method == 'POST' && path == '/api/sessions/rename') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
        final title = (map['title'] as String?)?.trim() ?? '';
        await controller.renameSession(sessionId, title);
        _sendJson(request.response, {'accepted': true});
      } else if (request.method == 'POST' && path == '/api/sessions/delete') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final sessionId = (map['sessionId'] as String?)?.trim() ?? '';
        await controller.deleteSession(sessionId);
        _sendJson(request.response, {'accepted': true});
      } else if (request.method == 'POST' && path == '/api/sessions/clear') {
        await controller.clearAllHistory();
        _sendJson(request.response, {'accepted': true});
      } else if (request.method == 'GET' && path == '/api/export-html') {
        final html = await controller.chatHistoryService
            .buildExportHtml(controller.sessions);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.headers.set(
          'Content-Disposition',
          'attachment; filename="side_assistant_history.html"',
        );
        request.response.write(html);
        await request.response.close();
      } else if (request.method == 'GET' && path == '/api/image') {
        final msgId = request.uri.queryParameters['msgId']?.trim() ?? '';
        String? imgPath;
        for (final m in controller.messages) {
          if (m.id == msgId && m.imagePath != null) {
            imgPath = m.imagePath;
            break;
          }
        }
        if (imgPath == null) {
          for (final s in controller.sessions) {
            for (final m in s.messages) {
              if (m.id == msgId && m.imagePath != null) {
                imgPath = m.imagePath;
                break;
              }
            }
          }
        }
        if (imgPath != null && File(imgPath).existsSync()) {
          final bytes = await File(imgPath).readAsBytes();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(bytes);
          await request.response.close();
        } else {
          _sendJson(
            request.response,
            {'error': 'Image not found'},
            status: HttpStatus.notFound,
          );
        }
      } else if (request.method == 'GET' && path == '/api/settings') {
        _sendJson(request.response, {
          'settings': controller.settings.toMap(),
        });
      } else if (request.method == 'POST' && path == '/api/settings') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final merged = Map<String, dynamic>.from(controller.settings.toMap())
          ..addAll(map);
        final newSettings = AppSettings.fromMap(merged);
        await controller.updateSettings(newSettings);
        _sendJson(request.response, {
          'accepted': true,
          'settings': controller.settings.toMap(),
        });
      } else if (request.method == 'GET' && path == '/api/hardware-devices') {
        final inputDevices = await AudioInputDeviceService.listInputDevices();
        final outputDevices = await LinuxHardwareService.listOutputDevices();
        final cameraDevices = await LinuxHardwareService.listCameraDevices();
        _sendJson(request.response, {
          'inputDevices': inputDevices
              .map((d) => {
                    'id': d.id,
                    'label': d.label,
                    'bluetooth': d.isBluetooth,
                    'type': d.type,
                  })
              .toList(),
          'outputDevices': outputDevices.map((d) => d.toMap()).toList(),
          'cameraDevices': cameraDevices.map((d) => d.toMap()).toList(),
        });
      } else if (request.method == 'POST' && path == '/api/fetch-models') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final baseUrl = (map['baseUrl'] as String?)?.trim() ??
            controller.settings.openAiBaseUrl;
        final apiKey = (map['apiKey'] as String?)?.trim() ??
            controller.settings.openAiApiKey;
        try {
          final models = await LlmService.fetchAvailableModels(
            baseUrl: baseUrl,
            apiKey: apiKey,
          );
          if (models.isNotEmpty) {
            controller.settings.cachedAvailableModels = models;
            await controller.settings.save();
          }
          _sendJson(request.response, {'models': models});
        } catch (e) {
          _sendJson(request.response, {'models': const [], 'error': '$e'});
        }
      } else if (request.method == 'POST' && path == '/api/volume') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final vol =
            (map['volume'] as num?)?.toInt() ?? controller.settings.playbackVolume;
        await controller.setPlaybackVolume(vol);
        _sendJson(request.response, {
          'accepted': true,
          'playbackVolume': controller.settings.playbackVolume,
        });
      } else if (request.method == 'POST' && path == '/api/mic-test') {
        final bodyStr = await utf8.decodeStream(request);
        final map = bodyStr.trim().isNotEmpty
            ? (jsonDecode(bodyStr) as Map<String, dynamic>)
            : <String, dynamic>{};
        final enabled = (map['enabled'] as bool?) ?? !controller.isMicTesting;
        final clear = (map['clear'] as bool?) ?? false;
        await controller.setMicTestMode(enabled, clear: clear);
        _sendJson(request.response, {
          'accepted': true,
          'isMicTesting': controller.isMicTesting,
          'isMicListening': controller.isMicListening,
          'micTestText': controller.micTestText,
          'micTestHistory': controller.micTestHistory,
        });
      } else if (request.method == 'POST' && path == '/api/test-embedding') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final phrase = (map['phrase'] as String?)?.trim() ?? '';
        try {
          final result = await controller.testTriggerPhraseSimilarity(phrase);
          _sendJson(request.response, result);
        } catch (e) {
          _sendJson(request.response, {'error': '$e'});
        }
      } else if (request.method == 'POST' && path == '/api/test-gemini') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final apiKey = map['apiKey'] as String?;
        final model = map['model'] as String?;
        final result = await controller.testGeminiAsrConnection(
          apiKey: apiKey,
          model: model,
        );
        _sendJson(request.response, {'result': result});
      } else if (request.method == 'POST' && path == '/api/preview-voice') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final voice =
            (map['voice'] as String?)?.trim() ?? controller.settings.edgeVoice;
        final text = (map['text'] as String?)?.trim() ??
            '你好，我是随身语音管家，很高兴为你服务。';
        unawaited(controller.ttsService.previewVoice(voice: voice, text: text));
        _sendJson(request.response, {'accepted': true});
      } else if (request.method == 'POST' && path == '/api/test-camera') {
        final bodyStr = await utf8.decodeStream(request);
        final map = bodyStr.trim().isNotEmpty
            ? (jsonDecode(bodyStr) as Map<String, dynamic>)
            : <String, dynamic>{};
        final dev = (map['device'] as String?)?.trim();
        if (dev != null) {
          controller.settings.linuxCameraDevice = dev;
        }
        try {
          final shot = await controller.cameraService.capturePhoto();
          _sendJson(request.response, {
            'accepted': true,
            'byteLength': shot.imageBytes.length,
            'filePath': shot.filePath,
            'isSimulated': shot.isSimulated,
            'base64': base64Encode(shot.imageBytes),
          });
        } catch (e) {
          _sendJson(request.response, {'error': '$e'});
        }
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
        final text = await controller.asrService.transcribeAudioFile(
          filePath,
          isStandbyWakeCheck: isStandby,
        );
        _sendJson(request.response, {
          'accepted': true,
          'path': filePath,
          'recognized': text,
        });
      } else if (request.method == 'GET' && path == '/audio-devices') {
        final devices = await AudioInputDeviceService.listInputDevices();
        _sendJson(request.response, {
          'configuredId': controller.settings.audioInputDeviceId,
          'configuredLabel': controller.settings.audioInputDeviceLabel,
          'activeLabel': controller.activeAudioInputDeviceLabel,
          'isListening': controller.isMicListening,
          'devices': devices
              .map((d) => {
                    'id': d.id,
                    'label': d.label,
                    'bluetooth': d.isBluetooth,
                    'type': d.type,
                  })
              .toList(),
        });
      } else if (request.method == 'POST' && path == '/audio-device') {
        final bodyStr = await utf8.decodeStream(request);
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        final id = (map['id'] as String?)?.trim() ?? '';
        var label = (map['label'] as String?)?.trim() ?? '';
        if (label.isEmpty && id.isNotEmpty) {
          final devices = await AudioInputDeviceService.listInputDevices();
          for (final d in devices) {
            if (d.id == id) {
              label = d.label;
              break;
            }
          }
        }
        await controller.setAudioInputDevice(id, label);
        _sendJson(request.response, {
          'accepted': true,
          'configuredId': controller.settings.audioInputDeviceId,
          'configuredLabel': controller.settings.audioInputDeviceLabel,
          'activeLabel': controller.activeAudioInputDeviceLabel,
          'isListening': controller.isMicListening,
        });
      } else if (request.method == 'POST' && path == '/run-self-test') {
        final report = await controller.runDiagnosticSelfTest();
        _sendJson(request.response, report);
      } else if (request.method == 'GET' && path == '/test-results') {
        _sendJson(request.response, {
          'isSelfTesting': controller.isSelfTesting,
          'logs': controller.selfTestLogs,
        });
      } else {
        _sendJson(
          request.response,
          {'error': 'Not found'},
          status: HttpStatus.notFound,
        );
      }
    } catch (e) {
      _sendJson(
        request.response,
        {'error': e.toString()},
        status: HttpStatus.internalServerError,
      );
    }
  }

  void _sendJson(
    HttpResponse response,
    Map<String, dynamic> data, {
    int status = HttpStatus.ok,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }
}
