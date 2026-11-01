import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';

/// 麦克风与音频流录制/转录处理器：
/// - POST /toggle-mic: 开启/暂停麦克风持续监听
/// - POST /api/manual-record/start: 开始手动按住对讲录音
/// - POST /api/manual-record/stop: 结束手动对讲录音
/// - POST /api/mic-test: 开启/关闭麦克风实时测音诊断模式
/// - POST /process-audio: 处理指定路径的本地音频文件输入
/// - POST /transcribe: 调用当前生效 ASR 引擎转录指定音频文件
class AudioHandler extends BaseHandler {
  AudioHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.post('/toggle-mic', handleToggleMic);
    router.post('/api/manual-record/start', handleManualRecordStart);
    router.post('/api/manual-record/stop', handleManualRecordStop);
    router.post('/api/mic-test', handleMicTest);
    router.post('/process-audio', handleProcessAudio);
    router.post('/transcribe', handleTranscribe);
  }

  Future<void> handleToggleMic(RequestContext ctx) async {
    await driverPort.toggleMicListening();
    ctx.sendJson({
      'accepted': true,
      'isMicListening': driverPort.isMicListening,
      'statusHint': driverPort.statusHint,
    });
  }

  Future<void> handleManualRecordStart(RequestContext ctx) async {
    await driverPort.startManualRecording();
    ctx.sendJson({
      'accepted': true,
      'isManualRecording': driverPort.isManualRecording,
    });
  }

  Future<void> handleManualRecordStop(RequestContext ctx) async {
    await driverPort.stopManualRecording();
    ctx.sendJson({
      'accepted': true,
      'isManualRecording': driverPort.isManualRecording,
    });
  }

  Future<void> handleMicTest(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final enabled = (map['enabled'] as bool?) ?? !driverPort.isMicTesting;
    final clear = (map['clear'] as bool?) ?? false;
    await driverPort.setMicTestMode(enabled, clear: clear);
    ctx.sendJson({
      'accepted': true,
      'isMicTesting': driverPort.isMicTesting,
      'isMicListening': driverPort.isMicListening,
      'micTestText': driverPort.micTestText,
      'micTestHistory': driverPort.micTestHistory,
    });
  }

  Future<void> handleProcessAudio(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final filePath = (map['path'] as String?)?.trim() ?? '';
    await driverPort.processAudioFile(filePath);
    ctx.sendJson({
      'accepted': true,
      'path': filePath,
      'lastRecognized': driverPort.lastRecognizedSpeech,
      'liveTranscript': driverPort.liveTranscript,
      'status': driverPort.status.name,
    });
  }

  Future<void> handleTranscribe(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final filePath = (map['path'] as String?)?.trim() ?? '';
    final isStandby = (map['isStandby'] as bool?) ?? false;
    final text = await driverPort.transcribeAudioFile(
      filePath,
      isStandbyWakeCheck: isStandby,
    );
    ctx.sendJson({
      'accepted': true,
      'path': filePath,
      'recognized': text,
    });
  }
}
