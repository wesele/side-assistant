import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue_intent_coordinator.dart';
import 'package:side_assistant/core/engine/coordinators/session_coordinator.dart';
import 'package:side_assistant/core/engine/coordinators/voice_pipeline_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/assistant_status.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/services/llm/llm_service.dart';
import 'package:side_assistant/services/storage/chat_history_service.dart';

class MockDialogueLlmService extends LlmService {
  int sendChatStreamCount = 0;
  final List<String> receivedQueries = [];

  MockDialogueLlmService(AppSettings settings) : super(settings: settings);

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
    sendChatStreamCount++;
    receivedQueries.add(newUserContent);
    yield '{"intent":"chat","reply":"对话测试回复：$newUserContent"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async {
      if (methodCall.method == 'hasPermission') return true;
      if (methodCall.method == 'isRecording') return false;
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
    const MethodChannel('flutter_tts'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (methodCall) async => '.',
  );
  HttpOverrides.global = null;

  AppSettings buildDialogueTestSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: false,
        enableBargeIn: true,
        silenceTimeoutSeconds: 5,
        startWordMode: AppConstants.startWordModeEnabled,
      );

  group(
      'DialogueIntentCoordinator 独立单元与契约测试 (DialogueIntentCoordinator Unit Tests)',
      () {
    late SessionCoordinator sessionCoordinator;
    late VoicePipelineCoordinator voiceCoordinator;
    late DialogueIntentCoordinator coordinator;
    late MockDialogueLlmService mockLlm;
    late List<AssistantEngineEvent> emittedEvents;
    late int notifyCount;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      emittedEvents = [];
      notifyCount = 0;

      final settings = buildDialogueTestSettings();

      sessionCoordinator = SessionCoordinator(
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        chatHistoryService: ChatHistoryService(),
      );
      await sessionCoordinator.loadChatHistory();

      voiceCoordinator = VoicePipelineCoordinator(
        settings: settings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
      );

      mockLlm = MockDialogueLlmService(settings);

      coordinator = DialogueIntentCoordinator(
        settings: settings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        voiceCoordinator: voiceCoordinator,
        sessionCoordinator: sessionCoordinator,
        llmService: mockLlm,
      );
    });

    tearDown(() {
      coordinator.dispose();
      voiceCoordinator.dispose();
      sessionCoordinator.dispose();
    });

    test('1. 初始化状态正确性与基础状态机契约验证', () {
      expect(coordinator.status, equals(AssistantStatus.idle));
      expect(coordinator.liveTranscript, isEmpty);
      expect(coordinator.lastRecognizedSpeech, isEmpty);
      expect(coordinator.isWakeWordMatched, isFalse);
      expect(coordinator.isInContinuousMode, isFalse);
      expect(coordinator.isDisposed, isFalse);
      expect(coordinator.triggerMatcher, isNotNull);
      expect(coordinator.llmService, isNotNull);
      expect(coordinator.ttsService, isNotNull);
    });

    test('2. 唤醒词指令触发与状态机跃迁 (triggerWake: idle -> listeningContent)', () async {
      await coordinator.triggerWake(wakeWord: '小曼');

      expect(coordinator.status, equals(AssistantStatus.listeningContent));
      expect(coordinator.isWakeWordMatched, isTrue);

      final statusEvent = emittedEvents.firstWhere(
        (e) =>
            e is StatusChangedEvent &&
            e.status == AssistantStatus.listeningContent,
      ) as StatusChangedEvent;
      expect(statusEvent.hint, contains('收到唤醒指令'));
    });

    test('3. 文本流串行化队列处理与实时识别转写 (processRecognizedText)', () async {
      await coordinator.processRecognizedText('晓漫 帮我查今天的天气');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(coordinator.isWakeWordMatched, isTrue);
      expect(coordinator.status, equals(AssistantStatus.listeningContent));
      expect(coordinator.lastRecognizedSpeech, contains('晓漫 帮我查今天的天气'));

      final transcriptEvents =
          emittedEvents.whereType<TranscriptUpdatedEvent>().toList();
      expect(transcriptEvents, isNotEmpty);
      expect(transcriptEvents.last.lastRecognized, contains('晓漫 帮我查今天的天气'));
    });

    test('4. 结束词匹配与大模型提请决策流程 (_submitLiveTranscript)', () async {
      // 唤醒并输入带结束词的语音指令
      await coordinator.processRecognizedText('晓漫 介绍一下杭州 回答');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 验证大模型被成功触发
      expect(mockLlm.sendChatStreamCount, equals(1));
      expect(mockLlm.receivedQueries.first, contains('介绍一下杭州'));
      expect(mockLlm.receivedQueries.first, isNot(contains('回答')));
    });

    test('5. 连续对话生命周期与模式转换 (enterContinuousMode & exitContinuousMode)',
        () async {
      coordinator.settings.startWordMode = AppConstants.startWordModeAuto;

      coordinator.enterContinuousMode();
      expect(coordinator.isInContinuousMode, isTrue);

      final enterEvent = emittedEvents.firstWhere(
        (e) => e is ContinuousModeChangedEvent && e.isInContinuousMode,
      );
      expect(enterEvent, isNotNull);

      await coordinator.exitContinuousMode(byUser: true);
      expect(coordinator.isInContinuousMode, isFalse);

      final exitEvent = emittedEvents.lastWhere(
        (e) => e is ContinuousModeChangedEvent && !e.isInContinuousMode,
      );
      expect(exitEvent, isNotNull);
    });

    test('6. 播报期间即时打断状态变迁与声学缓冲冷却 (handlePlayingBargeIn)', () async {
      coordinator.setStatus(AssistantStatus.playing, '正在播报回复');

      // 输入打断词“停止”
      await coordinator.handlePlayingBargeIn('停止');

      expect(coordinator.status, equals(AssistantStatus.idle));
      expect(coordinator.statusHint, contains('已停止朗读'));

      // 重新切到播报并使用唤醒新指令打断
      coordinator.setStatus(AssistantStatus.playing, '正在播报回复');
      await coordinator.handlePlayingBargeIn('小曼 别说了 换个话题');

      expect(coordinator.status, equals(AssistantStatus.listeningContent));
      expect(coordinator.liveTranscript, contains('换个话题'));
    });

    test('7. 直接用户消息与纯文本消息提交 (sendDirectUserMessage & sendTextMessage)',
        () async {
      await coordinator.sendDirectUserMessage('直接语音发送消息');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(mockLlm.sendChatStreamCount, equals(1));
      expect(mockLlm.receivedQueries.last, equals('直接语音发送消息'));

      // 发送纯文本消息
      await coordinator.sendTextMessage('纯文本测试');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(mockLlm.sendChatStreamCount, equals(2));
      expect(mockLlm.receivedQueries.last, equals('纯文本测试'));
    });

    test('8. 配置局部增量更新与协调器优雅销毁 (updateSettings & dispose)', () {
      final newSettings = buildDialogueTestSettings()..startWord = '你好小曼';
      coordinator.updateSettings(newSettings);

      expect(coordinator.settings.startWord, equals('你好小曼'));

      // 销毁协调器验证资源释放
      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);
    });
  });
}
