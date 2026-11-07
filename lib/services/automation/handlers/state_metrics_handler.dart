import 'dart:io';
import 'base_handler.dart';
import '../../../core/ports/assistant_driver_port.dart';
import '../http_router.dart';
import '../request_context.dart';
import '../sse_client_manager.dart';
import '../../../core/models/audio_input_device_kind.dart';
import '../../../core/platform/linux/linux_hardware_adapter.dart';

/// 系统状态与性能指标处理器：
/// - GET /health: 基础健康检查
/// - GET /status: 简要运行状态与 CPU 占用
/// - GET /api/state: 包含全部 40 个运行时状态字段的完整状态 Map
/// - GET /api/events: 基于 SSE 的实时全量状态事件流
class StateMetricsHandler extends BaseHandler {
  final SseClientManager sseManager;
  final int port;

  StateMetricsHandler({
    required AssistantDriverPort driverPort,
    required this.sseManager,
    required this.port,
  }) : super(driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/health', handleHealth, requiresAuth: false);
    router.get('/status', handleStatus, requiresAuth: true);
    router.get('/api/state', handleState, requiresAuth: true);
    router.get('/api/events', handleEvents, requiresAuth: true);
  }

  AudioInputDeviceKind get _activeDeviceKind => classifyAudioInputDevice(
        driverPort.activeAudioInputDeviceLabel,
        id: driverPort.settings.audioInputDeviceId,
      );

  Map<String, int> _speakerDomainCounts() {
    final embeddings = driverPort.settings.ownerSpeakerEmbeddings;
    final tags = driverPort.settings.ownerSpeakerDomains;
    var wideband = 0;
    var narrowband = 0;
    for (var i = 0; i < embeddings.length; i++) {
      final domain = i < tags.length ? tags[i] : speakerDomainWideband;
      if (domain == speakerDomainNarrowband) {
        narrowband++;
      } else {
        wideband++;
      }
    }
    return {'wideband': wideband, 'narrowband': narrowband};
  }

  Map<String, dynamic> _deviceState() {
    final kind = _activeDeviceKind;
    final label = driverPort.activeAudioInputDeviceLabel;
    return {
      'audioInputDevice': label,
      'audioInputDeviceKind': audioInputDeviceKindName(kind),
      'audioInputDeviceKindLabel': audioInputDeviceKindLabel(kind),
      'audioInputDeviceIsBluetooth': kind == AudioInputDeviceKind.bluetooth,
      'speakerAcousticDomain': speakerDomainFor(
        deviceLabel: label,
        deviceId: driverPort.settings.audioInputDeviceId,
      ),
    };
  }

  Map<String, dynamic> buildFullStateMap() {
    return {
      'platform': Platform.isLinux
          ? 'Linux Server'
          : (Platform.isWindows ? 'Windows' : Platform.operatingSystem),
      'status': driverPort.status.name,
      'statusHint': driverPort.statusHint,
      'cpuUsage': LinuxHardwareService.getCpuUsagePercent(),
      'liveTranscript': driverPort.liveTranscript,
      'displayTranscript': driverPort.displayTranscript,
      'lastRecognizedSpeech': driverPort.lastRecognizedSpeech,
      'isWakeWordMatched': driverPort.isWakeWordMatched,
      'isMicListening': driverPort.isMicListening,
      'isManualRecording': driverPort.isManualRecording,
      'isQuickCapturing': driverPort.isQuickCapturing,
      'micLevel': driverPort.micLevel,
      'micDbfs': driverPort.micDbfs,
      'vadDetected': driverPort.vadDetected,
      'isMicTesting': driverPort.isMicTesting,
      'micTestText': driverPort.micTestText,
      'micTestHistory': driverPort.micTestHistory,
      'playbackVolume': driverPort.settings.playbackVolume,
      'enableSpeakerVerification':
          driverPort.settings.enableSpeakerVerification,
      'speakerSimilarityThreshold':
          driverPort.settings.speakerSimilarityThreshold,
      'speakerVerifyWakeOnly': driverPort.settings.speakerVerifyWakeOnly,
      'enableTargetSpeakerExtraction':
          driverPort.settings.enableTargetSpeakerExtraction,
      'tseAttenuationDb': driverPort.settings.tseAttenuationDb,
      'enrolledSpeakerCount': driverPort.enrolledSpeakerCount,
      'hasEnrolledOwner': driverPort.hasEnrolledOwner,
      'speakerDomainCounts': _speakerDomainCounts(),
      'enableStartWordDetection': driverPort.settings.enableStartWordDetection,
      'startWordMode': driverPort.settings.startWordMode,
      'continuousModeTimeoutMinutes':
          driverPort.settings.continuousModeTimeoutMinutes,
      'isInContinuousMode': driverPort.isInContinuousMode,
      'silenceTimeoutSeconds': driverPort.settings.silenceTimeoutSeconds,
      'startWords': driverPort.settings.startWords,
      'endWords': driverPort.settings.endWords,
      'resetWords': driverPort.settings.resetWords,
      'exitContinuousWords': driverPort.settings.exitContinuousWords,
      'currentSessionId': driverPort.currentSessionId,
      'messageCount': driverPort.messages.length,
      'isSelfTesting': driverPort.isSelfTesting,
      'selfTestLogs': driverPort.selfTestLogs,
      ..._deviceState(),
      'messages': driverPort.messages.map((m) => m.toMap()).toList(),
      'sessions': driverPort.sessions
          .map((s) => {
                'id': s.id,
                'title': s.title,
                'createdAt': s.createdAt.toIso8601String(),
                'updatedAt': s.updatedAt.toIso8601String(),
                'messageCount': s.messages.length,
              })
          .toList(),
      'lastMessage': driverPort.messages.isNotEmpty
          ? driverPort.messages.last.toMap()
          : null,
    };
  }

  void handleHealth(RequestContext ctx) {
    ctx.sendJson({
      'status': 'ok',
      'app': 'SideAssistant',
      'platform': Platform.operatingSystem,
      'port': port,
    });
  }

  void handleStatus(RequestContext ctx) {
    ctx.sendJson({
      'status': driverPort.status.name,
      'statusHint': driverPort.statusHint,
      'cpuUsage': LinuxHardwareService.getCpuUsagePercent(),
      'liveTranscript': driverPort.liveTranscript,
      'currentSessionId': driverPort.currentSessionId,
      'messageCount': driverPort.messages.length,
      'isSelfTesting': driverPort.isSelfTesting,
      ..._deviceState(),
      'lastMessage': driverPort.messages.isNotEmpty
          ? driverPort.messages.last.toMap()
          : null,
    });
  }

  void handleState(RequestContext ctx) {
    ctx.sendJson(buildFullStateMap());
  }

  void handleEvents(RequestContext ctx) {
    sseManager.addClient(ctx.response, buildFullStateMap());
  }
}
