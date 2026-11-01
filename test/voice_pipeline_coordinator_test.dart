import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/voice_pipeline_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/core/models/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async {
      if (methodCall.method == 'hasPermission') return true;
      if (methodCall.method == 'isRecording') return false;
      if (methodCall.method == 'start') return null;
      if (methodCall.method == 'stop') return 'test.wav';
      return null;
    },
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (methodCall) async => '.',
  );
  HttpOverrides.global = null;

  AppSettings buildVoiceTestSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: false,
        enableSpeakerVerification: false,
      );

  group('VoicePipelineCoordinator 独立单元与契约测试 (VoicePipelineCoordinator Unit Tests)', () {
    late VoicePipelineCoordinator coordinator;
    late List<AssistantEngineEvent> emittedEvents;
    late int notifyCount;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      emittedEvents = [];
      notifyCount = 0;

      coordinator = VoicePipelineCoordinator(
        settings: buildVoiceTestSettings(),
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('1. 初始化状态正确性与基础契约验证', () {
      expect(coordinator.isMicListening, isFalse);
      expect(coordinator.isManualRecording, isFalse);
      expect(coordinator.isMicTesting, isFalse);
      expect(coordinator.micLevel, equals(0.0));
      expect(coordinator.vadDetected, isFalse);
      expect(coordinator.isDisposed, isFalse);
      expect(coordinator.asrService, isNotNull);
      expect(coordinator.voiceListeningService, isNotNull);
      expect(coordinator.speakerVerificationService, isNotNull);
      expect(coordinator.targetSpeakerExtractionService, isNotNull);
    });

    test('2. 麦克风常驻监听启动、停止与切换控制 (start/stop/toggleContinuousListening)', () async {
      final initialActive = coordinator.isMicListening;

      await coordinator.toggleContinuousListening();
      expect(coordinator.isMicListening, isNot(equals(initialActive)));

      final micEvent = emittedEvents.firstWhere(
        (e) => e is MicListeningChangedEvent,
      ) as MicListeningChangedEvent;
      expect(micEvent.isListening, equals(coordinator.isMicListening));

      await coordinator.stopContinuousListening();
      expect(coordinator.isMicListening, isFalse);

      await coordinator.startContinuousListening();
      expect(coordinator.isMicListening, isTrue);
    });

    test('3. 手动录音状态机与事件契约 (startManualRecording & stopManualRecording)', () async {
      await coordinator.startManualRecording();
      expect(coordinator.isManualRecording, isTrue);

      final manualStartEvent = emittedEvents.firstWhere(
        (e) => e is MicListeningChangedEvent && e.isManualRecording,
      );
      expect(manualStartEvent, isNotNull);

      await coordinator.stopManualRecording();
      expect(coordinator.isManualRecording, isFalse);
    });

    test('4. VAD 指标更新与高频事件广播 (MetricsUpdatedEvent)', () {
      coordinator.voiceListeningService.onAudioLevelChanged?.call(0.68, -14.5, true);

      final metricsEvent = emittedEvents.firstWhere(
        (e) => e is MetricsUpdatedEvent,
      ) as MetricsUpdatedEvent;

      expect(metricsEvent.metrics.level, closeTo(0.68, 0.01));
      expect(metricsEvent.metrics.dbfs, closeTo(-14.5, 0.01));
      expect(metricsEvent.metrics.vadDetected, isTrue);
    });

    test('5. 麦克风诊断测试模式与历史记录管理 (setMicTestMode)', () async {
      await coordinator.setMicTestMode(true);
      expect(coordinator.isMicTesting, isTrue);

      // 触发识别回调
      coordinator.voiceListeningService.onMicTestRecognized?.call('测试语音文本', 1500);

      expect(coordinator.micTestText, equals('测试语音文本'));
      expect(coordinator.micTestHistory.length, equals(1));
      expect(coordinator.micTestHistory.first['text'], equals('测试语音文本'));
      expect(coordinator.micTestHistory.first['durationMs'], equals(1500));

      final testEvent = emittedEvents.lastWhere(
        (e) => e is MicTestUpdatedEvent,
      ) as MicTestUpdatedEvent;
      expect(testEvent.text, equals('测试语音文本'));

      // 清除历史
      await coordinator.setMicTestMode(false, clear: true);
      expect(coordinator.isMicTesting, isFalse);
      expect(coordinator.micTestText, isEmpty);
      expect(coordinator.micTestHistory, isEmpty);
    });

    test('6. 主人声纹校验决策逻辑 (verifyOwnerSpeaker)', () {
      // 默认未开启声纹校验时，应自动放行通过
      final passBypassed = coordinator.verifyOwnerSpeaker(contextHint: '测试');
      expect(passBypassed, isTrue);

      // 开启声纹校验但未录入主人，也应放行
      coordinator.settings.enableSpeakerVerification = true;
      final passNoOwner = coordinator.verifyOwnerSpeaker(contextHint: '测试');
      expect(passNoOwner, isTrue);

      // 模拟未匹配声纹的拒绝回调
      String? rejectedReason;
      coordinator.verifyOwnerSpeaker(
        contextHint: '测试唤醒',
        onRejected: (r) => rejectedReason = r,
      );
      // 未录入时仍为 true，故 rejectedReason 为 null
      expect(rejectedReason, isNull);
    });

    test('7. 音频输入设备查询与热切换 (listInputDevices & setAudioInputDevice)', () async {
      final devices = await coordinator.listInputDevices();
      expect(devices, isA<List>());

      await coordinator.setAudioInputDevice('virtual-mic-1', '测试麦克风设备');
      expect(coordinator.settings.audioInputDeviceId, equals('virtual-mic-1'));
      expect(coordinator.settings.audioInputDeviceLabel, equals('测试麦克风设备'));

      final devEvent = emittedEvents.firstWhere(
        (e) =>
            e is MicListeningChangedEvent &&
            e.activeDeviceLabel == '测试麦克风设备',
      );
      expect(devEvent, isNotNull);
    });

    test('8. ASR 引擎动态热切换与资源销毁 (switchAsrEngine & dispose)', () async {
      expect(coordinator.asrService.engineName, contains('Zipformer'));

      await coordinator.switchAsrEngine(AppConstants.asrEngineSenseVoice);
      expect(coordinator.settings.asrEngine, equals(AppConstants.asrEngineSenseVoice));

      // 验证生命周期销毁
      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);
    });
  });
}
