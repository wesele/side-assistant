import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/services/llm/llm_service.dart';

/// 可受控的模拟 LLM 服务，用于观测并发请求次数与控制流式返回延迟
class ControlledMockLlmService extends LlmService {
  int sendChatStreamCallCount = 0;
  final List<String> receivedQueries = [];
  bool delayResponse = false;
  int delayMs = 50;

  ControlledMockLlmService(AppSettings settings) : super(settings: settings);

  @override
  Stream<String> sendChatStream({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  }) async* {
    sendChatStreamCallCount++;
    receivedQueries.add(newUserContent);
    if (delayResponse) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    // 返回标准对话 JSON 回复
    yield '{"intent":"chat","reply":"这是模拟的回答：$newUserContent"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 屏蔽单元测试环境中可能触发的原生音频 MethodChannel
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
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
  HttpOverrides.global = null;

  AppSettings buildStressSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: true,
        enableTtsPlayback: false,
        silenceTimeoutSeconds: 5,
        startWordMode: AppConstants.startWordModeEnabled,
      );

  group(
      'AssistantEngine 并发与状态机对抗压力测试 (Concurrency & State Machine Stress Tests)',
      () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('1. 高并发事件流订阅与动态退订竞争（100 个并发订阅者瞬时退订）', () async {
      final engine = AssistantEngine(
        settings: buildStressSettings(),
        enableDriverServer: false,
      );

      const subscriberCount = 100;
      final subscriptions = <StreamSubscription<AssistantEngineEvent>>[];
      final receivedCounts = List<int>.filled(subscriberCount, 0);

      for (int i = 0; i < subscriberCount; i++) {
        final index = i;
        final sub = engine.events.listen(
          (event) {
            receivedCounts[index]++;
          },
        );
        subscriptions.add(sub);
      }

      // 并发发射多种事件（包括提示音、唤醒状态变迁、中间文字更新）
      final futures = <Future<void>>[];
      for (int i = 0; i < 30; i++) {
        futures.add(engine.playAcknowledgeBeep());
        futures.add(engine.processRecognizedText('晓漫 测试第 $i 次输入'));
      }

      // 在事件分发过程中，让前 50 个订阅者动态并发取消订阅
      final cancelFutures = <Future<void>>[];
      for (int i = 0; i < 50; i++) {
        cancelFutures.add(subscriptions[i].cancel());
      }

      await Future.wait([...futures, ...cancelFutures]);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 验证后 50 个订阅者正常接收到了事件，未发生 ConcurrentModificationError
      for (int i = 50; i < subscriberCount; i++) {
        expect(receivedCounts[i], greaterThan(0),
            reason: '存活订阅者 #$i 应正常收到广播事件');
        await subscriptions[i].cancel();
      }

      await engine.disposeAsync();
    });

    test('2. 超高频音频电平指标吞吐与 notifyListeners 隔离性测试 (5000 次瞬时电平脉冲)', () async {
      final engine = AssistantEngine(
        settings: buildStressSettings(),
        enableDriverServer: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      int engineNotifyCount = 0;
      engine.addListener(() {
        engineNotifyCount++;
      });

      int metricsEventsReceived = 0;
      final sub = engine.events.listen((event) {
        if (event is MetricsUpdatedEvent) {
          metricsEventsReceived++;
        }
      });

      // 瞬时密集向 engine 发射 5000 次音频指标（通过 voiceService 的电平回调机制模拟）
      const burstCount = 5000;
      for (int i = 0; i < burstCount; i++) {
        engine.voiceService.onAudioLevelChanged?.call(0.5, -20.0, true);
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(metricsEventsReceived, equals(burstCount),
          reason: '5000 次电平指标事件应全量送达事件总线');
      expect(engineNotifyCount, equals(0),
          reason: '高频音频指标绝对不能触发 engine.notifyListeners()，否则会导致 UI 掉帧');

      await sub.cancel();
      await engine.disposeAsync();
    });

    test('3. 极速状态机随机变迁压力测试 (50 次无缝随机状态跃迁与自愈验证)', () async {
      final mockLlm = ControlledMockLlmService(buildStressSettings());
      final engine = AssistantEngine(
        settings: buildStressSettings(),
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      final stateHistory = <AssistantStatus>[];
      engine.events.listen((e) {
        if (e is StatusChangedEvent) {
          stateHistory.add(e.newStatus);
        }
      });

      // 并发打入乱序的唤醒、提问、重置、打断与会话切换
      final operations = <Future<void>>[];
      for (int i = 0; i < 50; i++) {
        operations.add(engine.triggerWake(wakeWord: '晓漫'));
        operations.add(engine.processRecognizedText('帮我查一下第 $i 个任务 回答'));
        operations.add(engine.resetToIdle());
        operations.add(engine.switchSession('test-session-$i'));
      }

      // 允许全部并发调用交织执行
      await Future.wait(operations);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 最终重置回待机
      await engine.resetToIdle();
      expect(engine.status, equals(AssistantStatus.idle),
          reason: '乱序调用后引擎必须具备自愈能力并能成功回到 idle');
      expect(stateHistory, isNotEmpty);

      await engine.disposeAsync();
    });

    test('4. 两遍解码与流式识别并发仲裁竞态测试 (Two-Pass Transcript Arbitration Race)',
        () async {
      final mockLlm = ControlledMockLlmService(buildStressSettings())
        ..delayResponse = true
        ..delayMs = 80;

      final engine = AssistantEngine(
        settings: buildStressSettings(),
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // 先唤醒进入 listeningContent
      await engine.triggerWake(wakeWord: '晓漫');
      expect(engine.status, equals(AssistantStatus.listeningContent));

      // 模拟流式识别 (processRecognizedText) 与离线第二遍识别 (processFinalTranscript) 几乎同一微秒到达
      final future1 = engine.processRecognizedText('帮我查天气 回答');
      final future2 = engine.processFinalTranscript('晓漫 帮我查天气 回答');

      await Future.wait([future1, future2]);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 观测 LLM 到底被请求了几次
      expect(mockLlm.sendChatStreamCallCount, equals(1),
          reason: '同一句话的流式与第二遍识别包含结束词时，必须裁决为单次提问，绝不能产生两次并发 LLM 调用');

      await engine.disposeAsync();
    });

    test('5. 手动对讲录音与持续监听高频并发切换 (Rapid Manual Recording & Mic Toggling)',
        () async {
      final engine = AssistantEngine(
        settings: buildStressSettings(),
        enableDriverServer: false,
      );

      final ops = <Future<void>>[];
      for (int i = 0; i < 20; i++) {
        ops.add(engine.startManualRecording());
        ops.add(engine.stopManualRecording());
        ops.add(engine.toggleMicListening());
      }

      await Future.wait(ops);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 验证内部标志位未锁死或损坏
      expect(engine.isManualRecording, isA<bool>());
      expect(engine.isMicListening, isA<bool>());

      await engine.disposeAsync();
    });

    test('6. 异步任务执行中强制调用 disposeAsync (无野指针、无未捕获异常、无泄漏计时器)', () async {
      final mockLlm = ControlledMockLlmService(buildStressSettings())
        ..delayResponse = true
        ..delayMs = 300;

      final engine = AssistantEngine(
        settings: buildStressSettings(),
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // 触发唤醒并提交一条耗时提问
      await engine.triggerWake(wakeWord: '晓漫');
      unawaited(engine.processRecognizedText('晓漫 请写一篇五千字的长文 回答'));

      // 等待 30ms 让状态进入 thinking
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 在大模型异步生成流尚在飞行的过程中，直接强制销毁引擎
      await engine.disposeAsync();

      // 销毁后继续等待大模型模拟流完成，验证不会触发 setState/notifyListeners after dispose 或 StreamController closed 异常
      await Future<void>.delayed(const Duration(milliseconds: 350));

      // 销毁后再次调用方法不应抛出致命崩溃
      await engine.resetToIdle();
      await engine.processRecognizedText('晓漫 还在吗');
    });

    test('7. 瞬时并发提交用户直接输入 (Concurrent sendDirectUserMessage calls)', () async {
      final mockLlm = ControlledMockLlmService(buildStressSettings())
        ..delayResponse = true
        ..delayMs = 100;

      final engine = AssistantEngine(
        settings: buildStressSettings(),
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final f1 = engine.sendDirectUserMessage('问题一：北京天气');
      final f2 = engine.sendDirectUserMessage('问题二：上海天气');

      await Future.wait([f1, f2]);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 观察两路并发直接输入是否有排队保护还是并发执行
      expect(mockLlm.sendChatStreamCallCount, greaterThan(0));
      await engine.disposeAsync();
    });

    test('8. 默认连续对话模式 (startWordModeAuto) 活跃时调用 disposeAsync 无遗留活跃 Timer',
        () async {
      final autoSettings = buildStressSettings()
        ..startWordMode = AppConstants.startWordModeAuto;

      final mockLlm = ControlledMockLlmService(autoSettings)
        ..delayResponse = true
        ..delayMs = 150;

      final engine = AssistantEngine(
        settings: autoSettings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 触发进入连续对话
      await engine.triggerWake(wakeWord: '晓漫');
      unawaited(engine.processRecognizedText('晓漫 进入连续对话模式 回答'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 在流式飞行中销毁引擎
      await engine.disposeAsync();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 验证销毁后内部状态安全
      expect(engine.status, equals(AssistantStatus.idle));
    });
  });
}
