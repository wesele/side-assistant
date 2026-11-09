import 'dart:async';
import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/models/camera_capture_result.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/pcm_stream_player_bridge.dart';
import '../../../core/ports/knowledge_port.dart';
import '../../llm/tools/custom_tool_manager.dart';
import 'gemini_live_dialog_protocol.dart';
import 'gemini_live_dialog_setup.dart';

/// Gemini Live 工具调用执行结果
class GeminiLiveToolExecutionResult {
  final List<Map<String, dynamic>> responses;
  final Uint8List? capturedPhotoBytes;

  const GeminiLiveToolExecutionResult({
    required this.responses,
    this.capturedPhotoBytes,
  });
}

/// Gemini Live 外部工具与原生能力执行调度器
class GeminiLiveToolExecutor {
  final AppSettings Function() getSettings;
  final PlatformPcmStreamPlayer pcmPlayer;
  final KnowledgePort? Function() getLightRagService;
  final void Function()? refreshLightRagService;
  final CustomToolManager customToolManager;
  final Future<CameraCaptureResult?> Function()? Function() getCapturePhoto;
  final void Function(String toolName, String query)? Function() getOnToolCall;
  final void Function(String text, String reason)? Function()
      getOnBackgroundSpeechDetected;
  final void Function(bool suppress) onSuppressCurrentTurnAudio;

  const GeminiLiveToolExecutor({
    required this.getSettings,
    required this.pcmPlayer,
    required this.getLightRagService,
    this.refreshLightRagService,
    required this.customToolManager,
    required this.getCapturePhoto,
    required this.getOnToolCall,
    required this.getOnBackgroundSpeechDetected,
    required this.onSuppressCurrentTurnAudio,
  });

  /// 执行下发的工具调用列表并根据双模（basic/advanced）与取消状态组装响应载荷
  Future<GeminiLiveToolExecutionResult> executeCalls({
    required List<GeminiLiveToolCall> calls,
    required bool isAdvanced,
    required Set<String> cancelledIds,
  }) async {
    final responses = <Map<String, dynamic>>[];
    Uint8List? capturedPhotoBytes;

    for (final call in calls) {
      if (cancelledIds.contains(call.id)) {
        debugPrint(
          '[GeminiLiveToolExecutor] 工具调用在执行前已被取消，跳过执行: '
          '${call.name} (id: ${call.id})',
        );
        cancelledIds.remove(call.id);
        continue;
      }

      if (call.name == 'record_background_speech') {
        onSuppressCurrentTurnAudio(true);
        await pcmPlayer.stopImmediate();
        final text = (call.args['text']?.toString() ?? '').trim();
        final reason = (call.args['reason']?.toString() ?? '').trim();
        getOnBackgroundSpeechDetected()?.call(text, reason);

        if (cancelledIds.contains(call.id)) {
          debugPrint(
            '[GeminiLiveToolExecutor] record_background_speech 调用已被取消，丢弃响应: '
            'id: ${call.id}',
          );
          cancelledIds.remove(call.id);
          continue;
        }

        responses.add(GeminiLiveDialogSetup.buildFunctionResponse(
          call.id,
          call.name,
          '已记录背景语音，请保持静默无需回复',
          scheduling: isAdvanced
              ? GeminiLiveDialogSetup.schedulingFor(call.name)
              : null,
        ));
        continue;
      }

      String resultText;
      if (call.name == 'capture_photo') {
        getOnToolCall()?.call('capture_photo', '');
        try {
          final captured = await getCapturePhoto()?.call();
          if (captured != null && captured.imageBytes.isNotEmpty) {
            capturedPhotoBytes = captured.imageBytes;
            resultText = '拍照成功';
          } else {
            resultText = '未能获取到摄像头画面';
          }
        } catch (e) {
          resultText = '拍照失败: $e';
        }
      } else if (call.name == 'lightrag_query') {
        final query = call.args['query']?.toString().trim() ?? '';
        final mode = call.args['mode']?.toString().trim() ?? 'mix';
        getOnToolCall()?.call('lightrag_query', query);
        try {
          refreshLightRagService?.call();
          final lightRag = getLightRagService();
          final res = query.isNotEmpty
              ? await lightRag?.queryContext(
                  query,
                  mode: mode.isEmpty ? 'mix' : mode,
                )
              : null;
          resultText =
              (res?.trim().isNotEmpty == true) ? res!.trim() : '未检索到相关记录';
        } catch (e) {
          resultText = '查询知识库异常: $e';
        }
      } else if (call.name == 'call_custom_tool') {
        final toolName = call.args['tool_name']?.toString().trim() ?? '';
        final rawArgs = call.args['arguments'];
        final argsJson = rawArgs is Map || rawArgs is List
            ? jsonEncode(rawArgs)
            : (rawArgs?.toString().trim() ?? '{}');
        getOnToolCall()?.call('call_custom_tool', toolName);
        try {
          resultText = await customToolManager.executeCustomTool(
            toolName,
            argsJson.isNotEmpty ? argsJson : '{}',
            settings: getSettings(),
          );
        } catch (e) {
          resultText = '执行自定义工具异常: $e';
        }
      } else if (call.name == 'invoke_opencode') {
        final desc = call.args['task_description']?.toString().trim() ?? '';
        final persistence =
            call.args['persistence']?.toString().trim() ?? 'temporary';
        final toolName = call.args['tool_name']?.toString().trim();
        final toolSummary = call.args['tool_summary']?.toString().trim();
        final paramsHint = call.args['parameters_hint']?.toString().trim();
        final rawInit = call.args['initial_arguments'];
        final initArgs = (rawInit is Map || rawInit is List)
            ? jsonEncode(rawInit)
            : rawInit?.toString().trim();
        final summary = toolName?.isNotEmpty == true
            ? toolName!
            : (toolSummary?.isNotEmpty == true
                ? toolSummary!
                : (desc.length > 30 ? '${desc.substring(0, 30)}...' : desc));
        getOnToolCall()?.call('invoke_opencode', summary);
        try {
          resultText = await customToolManager.invokeOpenCode(
            taskDescription: desc,
            persistence: persistence,
            toolName: toolName?.isNotEmpty == true ? toolName : null,
            toolSummary: toolSummary?.isNotEmpty == true ? toolSummary : null,
            parametersHint: paramsHint?.isNotEmpty == true ? paramsHint : null,
            initialArguments: initArgs?.isNotEmpty == true ? initArgs : null,
            settings: getSettings(),
          );
        } catch (e) {
          resultText = '调用 OpenCode 异常: $e';
        }
      } else {
        resultText = '不支持的工具: ${call.name}';
      }

      if (cancelledIds.contains(call.id)) {
        debugPrint(
          '[GeminiLiveToolExecutor] 工具调用执行后已被取消，丢弃响应: '
          '${call.name} (id: ${call.id})',
        );
        cancelledIds.remove(call.id);
        if (call.name == 'capture_photo') {
          capturedPhotoBytes = null;
        }
        continue;
      }

      responses.add(GeminiLiveDialogSetup.buildFunctionResponse(
        call.id,
        call.name,
        resultText,
        scheduling:
            isAdvanced ? GeminiLiveDialogSetup.schedulingFor(call.name) : null,
      ));
    }

    return GeminiLiveToolExecutionResult(
      responses: responses,
      capturedPhotoBytes: capturedPhotoBytes,
    );
  }
}
