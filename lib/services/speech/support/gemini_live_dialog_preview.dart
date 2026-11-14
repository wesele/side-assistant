import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/location_bridge.dart';
import '../../../core/ports/gemini_live_session_port.dart';
import '../../llm/tools/custom_tool_manager.dart';
import 'gemini_live_capabilities.dart';
import 'gemini_live_dialog_setup.dart';

/// Gemini 3.8 Live 会话握手组装与原生音色试听辅助器
class GeminiLiveDialogPreview {
  const GeminiLiveDialogPreview._();

  /// 打开与 Gemini Live `BidiGenerateContent` 的 WebSocket 连接并在过期时安全关闭。
  static Future<WebSocket?> openWebSocket({
    required String apiKey,
    Future<WebSocket> Function(String url)? connector,
    required bool Function() isStale,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final uri =
        '${AppConstants.geminiLiveWsUrl}?key=${Uri.encodeQueryComponent(apiKey)}';
    final connectFut = (connector ?? WebSocket.connect)(uri);
    unawaited(connectFut.then<void>((_) {}, onError: (Object _) {}));
    final socket = await connectFut.timeout(timeout);
    if (isStale()) {
      await socket.close();
      return null;
    }
    return socket;
  }

  static Future<Map<String, dynamic>> buildConnectSetupPayload({
    required AppSettings settings,
    required bool isPreview,
    required bool isAdvanced,
    required String? sessionResumptionHandle,
    required bool allowCapturePhoto,
    required CustomToolManager customToolManager,
  }) async {
    String? address;
    try {
      address = await LocationBridge.getCurrentAddress()
          .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
    } catch (_) {}

    final sysInstruction = GeminiLiveDialogSetup.buildSystemInstruction(
      settings,
      currentAddress: address,
      customToolManager: customToolManager,
    );
    final thinkingLevel = GeminiLiveCapabilities.normalizeThinkingLevel(
      settings.geminiLiveThinkingLevel,
    );
    final includeThoughts = settings.geminiLiveIncludeThoughts;

    return isPreview
        ? GeminiLiveDialogSetup.buildPreviewSetupMessage(
            settings: settings,
            systemInstructionOverride: sysInstruction,
            sessionResumptionHandle: sessionResumptionHandle,
            allowCapturePhoto: allowCapturePhoto,
            customToolManager: customToolManager,
            advanced: isAdvanced,
            thinkingLevel: thinkingLevel,
            includeThoughts: includeThoughts,
          )
        : GeminiLiveDialogSetup.buildSetupMessage(
            settings: settings,
            systemInstructionOverride: sysInstruction,
            sessionResumptionHandle: sessionResumptionHandle,
            allowCapturePhoto: allowCapturePhoto,
            customToolManager: customToolManager,
            advanced: isAdvanced,
            thinkingLevel: thinkingLevel,
            includeThoughts: includeThoughts,
          );
  }

  static Future<Uint8List?> resolveImageBytes(
    Uint8List? imageBytes,
    String? imagePath,
  ) async {
    if (imageBytes != null && imageBytes.isNotEmpty) return imageBytes;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final file = File(imagePath);
        if (file.existsSync()) return await file.readAsBytes();
      } catch (_) {}
    }
    return imageBytes;
  }

  static Future<Uint8List?> readWavPcm16(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final rawBytes = await file.readAsBytes();
    return rawBytes.length > 44 ? Uint8List.sublistView(rawBytes, 44) : null;
  }

  static String formatCloseReason(WebSocket? socket,
      {required bool wasConnecting}) {
    final closeCode = socket?.closeCode;
    final closeReason = socket?.closeReason;
    final hasReason = closeReason != null && closeReason.trim().isNotEmpty;
    final codePart = closeCode != null ? '$closeCode: ' : '';
    return hasReason
        ? '连接被服务端关闭 ($codePart${closeReason.trim()})'
        : (wasConnecting ? '连接被服务端关闭，请检查 API Key、模型名与网络' : 'Gemini Live 连接已断开');
  }

  static List<String> buildToolFollowupPayloads({
    required List<Map<String, dynamic>> responses,
    required Uint8List? capturedPhotoBytes,
    required bool isAdvanced,
  }) {
    final frames = <String>[
      if (responses.isNotEmpty)
        jsonEncode(GeminiLiveDialogSetup.buildToolResponseMessage(responses)),
      if (capturedPhotoBytes != null && capturedPhotoBytes.isNotEmpty)
        jsonEncode(GeminiLiveDialogSetup.buildClientTextMessage(
          '这是刚刚拍下的现场照片，请结合画面内容直接回答。',
          imageBytes: capturedPhotoBytes,
          turnComplete: !isAdvanced,
        )),
    ];
    return frames;
  }

  static Future<void> run({
    required AppSettings settings,
    required String voice,
    String? text,
    String? apiKey,
    String? model,
    required ({
      GeminiLiveSessionPort session,
      String? Function() lastError,
    })
        Function(
      AppSettings previewSettings,
      void Function() onTurnCompleted,
      void Function(String msg) onServerError,
    ) createProbe,
  }) async {
    final previewSettings = GeminiLiveDialogSetup.buildPreviewSettings(
      settings,
      voice: voice,
      apiKey: apiKey,
      model: model,
    );

    if (GeminiLiveDialogSetup.apiKey(previewSettings).isEmpty) {
      throw StateError('Gemini API Key 为空，请先在设置中填写');
    }

    final isAdvanced = GeminiLiveCapabilities.resolveAdvanced(
      mode: previewSettings.geminiLiveAdvancedMode,
      model: GeminiLiveDialogSetup.model(previewSettings),
    );
    final timeoutSeconds = isAdvanced ? 25 : 12;

    final turnCompleter = Completer<void>();
    final handle = createProbe(
      previewSettings,
      () {
        if (!turnCompleter.isCompleted) turnCompleter.complete();
      },
      (msg) {
        if (!turnCompleter.isCompleted) {
          turnCompleter.completeError(StateError(msg));
        }
      },
    );
    final probe = handle.session;

    try {
      final ok = await probe.connect();
      if (!ok) {
        throw StateError(handle.lastError() ?? '连接 Gemini Live 失败');
      }

      final promptText = (text == null || text.trim().isEmpty)
          ? '你好，我是晓漫，这是 Gemini Live $voice 原生音色的试听效果。'
          : text.trim();

      await probe.sendClientText('请直接用自然亲切的语气朗读这句话，不要添加任何多余解释：$promptText');

      await turnCompleter.future.timeout(Duration(seconds: timeoutSeconds));

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (probe.isSpeakingOutput && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      probe.dispose();
    }
  }
}
