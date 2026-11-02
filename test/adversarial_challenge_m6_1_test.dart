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

class SlowStreamingMockLlmService extends LlmService {
  int callCount = 0;
  final List<String> receivedQueries = [];

  SlowStreamingMockLlmService(AppSettings settings) : super(settings: settings);

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
    callCount++;
    receivedQueries.add(newUserContent);
    // Emits json response piece by piece with realistic thinking/generation delay
    yield '{"intent":"chat","reply":"这是第一句回复。';
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    yield '这是第二句回复。"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (methodCall) async => 1,
  );
  HttpOverrides.global = null;

  AppSettings buildTestSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: true,
        enableBargeIn: true,
        silenceTimeoutSeconds: 5,
        startWordMode: AppConstants.startWordModeEnabled,
      );

  group(
      'Adversarial Stress Test Suite: DialogueIntentCoordinator & AssistantEngine',
      () {
    test(
        'Bug 1: Barge-in is head-of-line blocked by _textProcessQueue awaiting submitToLlm',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings();
      final mockLlm = SlowStreamingMockLlmService(settings);
      final engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // 1. Simulating real VoiceListeningService calling onTextRecognized (fire-and-forget)
      unawaited(engine.processRecognizedText('晓漫 讲一个很长的故事 回答'));

      // Wait until engine enters thinking or playing
      int waitCount = 0;
      while (engine.status != AssistantStatus.playing && waitCount < 50) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waitCount++;
      }
      expect(engine.status, equals(AssistantStatus.playing));

      // 2. While playing, user speaks "停止" via voice recognition pipeline
      final stopwatch = Stopwatch()..start();
      await engine.processRecognizedText('停止');
      stopwatch.stop();

      // Bug verification: barge-in was queued behind the entire LLM stream and took >1200ms
      // Expected behavior: barge-in should interrupt active playback immediately (< 300ms)
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(300),
        reason:
            'Voice barge-in ("停止") must interrupt immediately, but took ${stopwatch.elapsedMilliseconds}ms due to queue head-of-line blocking!',
      );

      await engine.disposeAsync();
    });

    test(
        'Bug 2: Concurrent direct user input corrupts shared currentSpeakingReply state',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings();
      final mockLlm = SlowStreamingMockLlmService(settings);
      final engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // 1. Voice prompt starts
      unawaited(engine.processRecognizedText('晓漫 语音问题A 回答'));

      // Wait until engine is thinking or playing
      while (engine.status == AssistantStatus.idle) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // 2. User types manual message in UI at the same time
      final directFuture = engine.sendDirectUserMessage('手动问题B');

      // Wait until query 1 finishes (around 1200ms) while query 2 is still running
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      // At this point, query 2 is still streaming!

      // If query 1's finally block prematurely set status to idle, this assertion will reveal it:
      expect(
        engine.status == AssistantStatus.thinking ||
            engine.status == AssistantStatus.playing,
        isTrue,
        reason:
            'Engine status was prematurely set to idle by the first query while the second query was still streaming!',
      );

      await directFuture;
      await engine.disposeAsync();
    });

    test(
        'Bug 3: Continuous conversation mode cannot be exited via voice exit words ("退下"/"结束对话")',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings()
        ..startWordMode = AppConstants.startWordModeAuto
        ..exitContinuousWord = '结束对话;退下';
      final mockLlm = SlowStreamingMockLlmService(settings);
      final engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // Enter continuous conversation mode
      engine.dialogueCoordinator.enterContinuousMode();
      expect(engine.isInContinuousMode, isTrue);
      expect(engine.isWakeWordRequired, isFalse);

      // User speaks the exit command directly
      final initialLlmCalls = mockLlm.callCount;
      await engine.processRecognizedText('退下');

      // Bug verification: DialogueIntentCoordinator never calls checkExitContinuousWord in _handleIdleState
      expect(
        engine.isInContinuousMode,
        isFalse,
        reason:
            'Saying exit word "退下" in continuous mode must immediately exit continuous mode, but isInContinuousMode was still true!',
      );
      expect(
        mockLlm.callCount,
        equals(initialLlmCalls),
        reason: 'Local exit word should NOT trigger an LLM call',
      );

      await engine.disposeAsync();
    });

    test(
        'Bug 4: End word in continuous mode from idle state does not trigger immediate submission',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = buildTestSettings()
        ..startWordMode = AppConstants.startWordModeAuto;
      final mockLlm = SlowStreamingMockLlmService(settings);
      final engine = AssistantEngine(
        settings: settings,
        injectedLlmService: mockLlm,
        enableDriverServer: false,
      );

      // Enter continuous conversation mode
      engine.dialogueCoordinator.enterContinuousMode();
      expect(engine.isInContinuousMode, isTrue);

      // User says question ending with endWord directly from idle
      await engine.processRecognizedText('今天星期几回答');

      // Bug verification: _handleIdleState does not check endWord when !isWakeWordRequired
      expect(
        engine.status == AssistantStatus.thinking ||
            engine.status == AssistantStatus.playing,
        isTrue,
        reason:
            'Recognizing end word "回答" in continuous mode must immediately trigger thinking/answering, but engine remained in listeningContent waiting for silence timeout!',
      );

      await engine.disposeAsync();
    });
  });
}
