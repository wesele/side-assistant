import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/platform/pcm_stream_player_bridge.dart';
import 'package:side_assistant/services/speech/gemini_live_dialog_service.dart';
import 'package:side_assistant/services/speech/support/gemini_live_pcm.dart';

class _FakeWebSocket extends Stream<dynamic> implements WebSocket {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<dynamic> sentMessages = <dynamic>[];
  bool isClosed = false;

  void emit(dynamic data) {
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(dynamic data) {
    sentMessages.add(data);
    if (data is String && data.contains('setup')) {
      scheduleMicrotask(() {
        emit(jsonEncode(<String, dynamic>{
          'setupComplete': <String, dynamic>{},
        }));
      });
    }
  }

  @override
  Future<dynamic> close([int? code, String? reason]) async {
    isClosed = true;
    await _controller.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePcmPlayer extends PlatformPcmStreamPlayer {
  bool fakeIsPlaying = false;
  int stopImmediateCalls = 0;
  final List<Uint8List> fedPcmChunks = <Uint8List>[];

  @override
  bool get isPlaying => fakeIsPlaying;

  @override
  Future<void> feedPcm(
    Uint8List pcmBytes, {
    int sampleRate = 24000,
    int volumePercent = 100,
    String outputDeviceId = '',
  }) async {
    fedPcmChunks.add(pcmBytes);
  }

  @override
  Future<void> stopImmediate() async {
    stopImmediateCalls++;
    fakeIsPlaying = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GeminiLivePcm.resetConditioner();
    GeminiLivePcm.debugForceMobileEchoProfile = null;
  });

  tearDown(() {
    GeminiLivePcm.resetConditioner();
    GeminiLivePcm.debugForceMobileEchoProfile = null;
  });

  group('Gemini Live Mobile Echo & Barge-In Tests', () {
    test('1. Mobile Speaker Echo Suppression: 下行参考包络存在时，高频与谐波回声被全量消音且不触发插话',
        () {
      GeminiLivePcm.debugForceMobileEchoProfile = true;

      // 模拟下行 24kHz 外放 PCM，振幅约 0.22
      final outPcm = Uint8List(480 * 2);
      final bd = ByteData.sublistView(outPcm);
      for (var i = 0; i < 480; i++) {
        final s = 0.22 * math.sin(2 * math.pi * 440 * i / 24000);
        bd.setInt16(i * 2, (s * 32767).round(), Endian.little);
      }
      GeminiLivePcm.feedOutputPcm16(outPcm);
      expect(GeminiLivePcm.currentOutputRmsEnvelope, greaterThan(0.05));

      // 模拟 400ms (6400 采样 @ 16kHz) 扬声器回声（基频 0.035 + 二次谐波 0.015，RMS ~0.027）
      final echoSamples = Float32List(6400);
      for (var i = 0; i < echoSamples.length; i++) {
        final t = 2 * math.pi * 300 * i / 16000;
        echoSamples[i] =
            (0.035 * math.sin(t) + 0.015 * math.sin(2 * t)).toDouble();
      }

      var bargeInTriggered = false;
      final outBytes = GeminiLivePcm.processUplinkSamples(
        echoSamples,
        isInPlaybackEchoZone: true,
        onLocalBargeInTriggered: () => bargeInTriggered = true,
      );

      expect(bargeInTriggered, isFalse);
      expect(GeminiLivePcm.isBargeInActive, isFalse);
      expect(outBytes.length, equals(echoSamples.length * 2));
      expect(outBytes.every((b) => b == 0), isTrue);
    });

    test('2. Mobile Initial 450ms AEC Settling Window: 播报启动前 450ms 内中等响度不误触发打断',
        () {
      GeminiLivePcm.debugForceMobileEchoProfile = true;
      GeminiLivePcm.notifyPlaybackStarted();

      // 450ms 内的中等音量语音（RMS ~0.07，峰值约 0.10）
      final moderateSpeech = Float32List(4800);
      for (var i = 0; i < moderateSpeech.length; i++) {
        final t = 2 * math.pi * 250 * i / 16000;
        moderateSpeech[i] = (0.07 * math.sqrt(2) * math.sin(t)).toDouble();
      }

      var bargeInTriggered = false;
      final outBytes = GeminiLivePcm.processUplinkSamples(
        moderateSpeech,
        isInPlaybackEchoZone: true,
        onLocalBargeInTriggered: () => bargeInTriggered = true,
      );

      expect(bargeInTriggered, isFalse);
      expect(GeminiLivePcm.isBargeInActive, isFalse);
      expect(outBytes.every((b) => b == 0), isTrue);
    });

    test(
        '3. Mobile Genuine Loud Close-Talk Barge-In: 移动端真实大声近讲（RMS>0.14，Peak>=0.28）正常触发打断并透传',
        () {
      GeminiLivePcm.debugForceMobileEchoProfile = true;

      // 400ms (6400 采样 > 4800 门限) 真实大声近讲（0.20 基频 + 0.10 谐波，RMS > 0.14, Peak >= 0.28）
      final loudSpeech = Float32List(6400);
      for (var i = 0; i < loudSpeech.length; i++) {
        final t = 2 * math.pi * 250 * i / 16000;
        loudSpeech[i] =
            (0.20 * math.sin(t) + 0.10 * math.sin(2 * t)).toDouble();
      }

      var bargeInTriggered = false;
      final outBytes = GeminiLivePcm.processUplinkSamples(
        loudSpeech,
        isInPlaybackEchoZone: true,
        onLocalBargeInTriggered: () => bargeInTriggered = true,
      );

      expect(bargeInTriggered, isTrue);
      expect(GeminiLivePcm.isBargeInActive, isTrue);
      expect(outBytes.length, greaterThanOrEqualTo(loudSpeech.length * 2));
      expect(outBytes.any((b) => b != 0), isTrue);
    });

    test(
        '4. Mobile Leaky Integrator Fast Decay: 间歇性短促脉冲声音在移动端对称衰减，无法累积到 4800 样本',
        () {
      GeminiLivePcm.debugForceMobileEchoProfile = true;

      // 2 帧大声 (2 * 480 采样) + 2 帧安静回声 (2 * 480 采样)
      final loudFrame = Float32List(480);
      for (var i = 0; i < 480; i++) {
        final t = 2 * math.pi * 250 * i / 16000;
        loudFrame[i] = (0.20 * math.sin(t) + 0.10 * math.sin(2 * t)).toDouble();
      }
      final quietFrame = Float32List(480);
      for (var i = 0; i < 480; i++) {
        final t = 2 * math.pi * 1000 * i / 16000;
        quietFrame[i] = (0.01 * math.sin(t)).toDouble();
      }

      var bargeInTriggered = false;
      for (var cycle = 0; cycle < 15; cycle++) {
        GeminiLivePcm.processUplinkSamples(
          loudFrame,
          isInPlaybackEchoZone: true,
          onLocalBargeInTriggered: () => bargeInTriggered = true,
        );
        GeminiLivePcm.processUplinkSamples(
          loudFrame,
          isInPlaybackEchoZone: true,
          onLocalBargeInTriggered: () => bargeInTriggered = true,
        );
        GeminiLivePcm.processUplinkSamples(
          quietFrame,
          isInPlaybackEchoZone: true,
          onLocalBargeInTriggered: () => bargeInTriggered = true,
        );
        GeminiLivePcm.processUplinkSamples(
          quietFrame,
          isInPlaybackEchoZone: true,
          onLocalBargeInTriggered: () => bargeInTriggered = true,
        );
      }

      expect(bargeInTriggered, isFalse);
      expect(GeminiLivePcm.isBargeInActive, isFalse);
    });

    test(
        '5. Non-Destructive Mobile Barge-In: 移动端触发本地插话不掐断本地播放，由服务端 interrupted 最终执行打断',
        () async {
      final fakeSocket = _FakeWebSocket();
      final fakePlayer = _FakePcmPlayer()..fakeIsPlaying = true;

      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-api-key',
        ),
        pcmPlayer: fakePlayer,
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      expect(await service.connect(), isTrue);
      GeminiLivePcm.debugForceMobileEchoProfile = true;

      // 构造大声真实插话
      final loudSpeech = Float32List(6400);
      for (var i = 0; i < loudSpeech.length; i++) {
        final t = 2 * math.pi * 250 * i / 16000;
        loudSpeech[i] =
            (0.20 * math.sin(t) + 0.10 * math.sin(2 * t)).toDouble();
      }

      // 喂入音频，触发本地插话门限
      service.feedAudioSamples(loudSpeech);
      expect(GeminiLivePcm.isBargeInActive, isTrue);

      // 移动端保持非侵入式：stopImmediate 不在此刻调用
      expect(fakePlayer.stopImmediateCalls, equals(0));
      expect(fakePlayer.isPlaying, isTrue);

      // 收到服务端确认打断消息
      fakeSocket.emit(jsonEncode(<String, dynamic>{
        'serverContent': <String, dynamic>{'interrupted': true},
      }));
      await pumpEventQueue();

      // 服务端确认后正式停止本地播报
      expect(fakePlayer.stopImmediateCalls, equals(1));
    });

    test('6. Desktop Destructive Barge-In: 桌面端触发本地插话立即主动停止本地播报', () async {
      final fakeSocket = _FakeWebSocket();
      final fakePlayer = _FakePcmPlayer()..fakeIsPlaying = true;

      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-api-key',
        ),
        pcmPlayer: fakePlayer,
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      expect(await service.connect(), isTrue);
      GeminiLivePcm.debugForceMobileEchoProfile = false;

      // 桌面端 2400 采样插话信号
      final speechSamples = Float32List(3200);
      for (var i = 0; i < speechSamples.length; i++) {
        final t = 2 * math.pi * 200 * i / 16000;
        speechSamples[i] =
            (0.008 * math.sin(t) + 0.004 * math.sin(2 * t)).toDouble();
      }

      service.feedAudioSamples(speechSamples);
      expect(GeminiLivePcm.isBargeInActive, isTrue);

      // 桌面端立即停止播放
      expect(fakePlayer.stopImmediateCalls, equals(1));
    });

    test(
        '7. Playback-Synchronized onTurnCompleted: 物理播报未完成时不提前派发 turnComplete，待声卡排空后精准派发',
        () async {
      final fakeSocket = _FakeWebSocket();
      final fakePlayer = _FakePcmPlayer()..fakeIsPlaying = true;

      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-api-key',
        ),
        pcmPlayer: fakePlayer,
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      var turnCompletedCount = 0;
      service.onTurnCompleted = () => turnCompletedCount++;

      expect(await service.connect(), isTrue);

      // 下发协议层 turnComplete，但扬声器仍处于 isPlaying
      fakeSocket.emit(jsonEncode(<String, dynamic>{
        'serverContent': <String, dynamic>{'turnComplete': true},
      }));
      await pumpEventQueue();

      // 未排空前不派发
      expect(turnCompletedCount, equals(0));

      // 扬声器排空结束
      fakePlayer.fakeIsPlaying = false;

      // 100ms 轮询检测到排空后触发回调
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(turnCompletedCount, equals(1));
    });

    test(
        '8. Playback-Synchronized onTurnCompleted: 排空等待中若被 interrupted 或新轮次开启，取消延迟排空定时器',
        () async {
      final fakeSocket = _FakeWebSocket();
      final fakePlayer = _FakePcmPlayer()..fakeIsPlaying = true;

      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-api-key',
        ),
        pcmPlayer: fakePlayer,
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      var turnCompletedCount = 0;
      service.onTurnCompleted = () => turnCompletedCount++;

      expect(await service.connect(), isTrue);

      // 触发 turnComplete
      fakeSocket.emit(jsonEncode(<String, dynamic>{
        'serverContent': <String, dynamic>{'turnComplete': true},
      }));
      await pumpEventQueue();
      expect(turnCompletedCount, equals(0));

      // 中途收到 interrupted 打断上一轮排空
      fakeSocket.emit(jsonEncode(<String, dynamic>{
        'serverContent': <String, dynamic>{'interrupted': true},
      }));
      fakePlayer.fakeIsPlaying = false;

      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(turnCompletedCount, equals(0));
    });
  });
}
