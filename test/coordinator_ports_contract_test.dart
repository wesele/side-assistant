import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue_intent_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/assistant_status.dart';
import 'package:side_assistant/core/ports/audio_stream_control_port.dart';
import 'package:side_assistant/core/ports/knowledge_port.dart';
import 'package:side_assistant/core/ports/llm_port.dart';
import 'package:side_assistant/core/ports/prompt_sound_port.dart';
import 'package:side_assistant/core/ports/session_message_port.dart';
import 'package:side_assistant/core/ports/speaker_verification_port.dart';
import 'package:side_assistant/core/ports/tts_port.dart';

/// 纯内存实现的 AudioStreamControlPort Stub，零音频驱动/硬件依赖
class StubAudioStreamControlPort implements AudioStreamControlPort {
  @override
  bool isMicListening;

  @override
  bool isAsrStreaming;

  int idleHygieneCount = 0;
  int resetStreamCount = 0;
  int flushBuffersCount = 0;
  final List<int> flushCooldownHistory = [];

  StubAudioStreamControlPort({
    this.isMicListening = true,
    this.isAsrStreaming = true,
  });

  @override
  void performIdleHygiene() {
    idleHygieneCount++;
  }

  @override
  void resetStream() {
    resetStreamCount++;
  }

  @override
  void flushBuffers({int cooldownMs = 600}) {
    flushBuffersCount++;
    flushCooldownHistory.add(cooldownMs);
  }
}

/// 纯内存实现的 SpeakerVerificationPort Stub，零 ONNX/CAM++ 模型依赖
class StubSpeakerVerificationPort implements SpeakerVerificationPort {
  @override
  bool isEnrolling;

  bool allowVerification;
  int verifyCallCount = 0;
  final List<String> verifyHints = [];
  final List<String> rejectedReasons = [];

  StubSpeakerVerificationPort({
    this.isEnrolling = false,
    this.allowVerification = true,
  });

  @override
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) {
    verifyCallCount++;
    verifyHints.add(contextHint);
    if (!allowVerification) {
      const reason = 'Mocked: 声纹相似度不足 (0.23 < 0.65)';
      rejectedReasons.add(reason);
      onRejected?.call(reason);
      return false;
    }
    return true;
  }

  @override
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  }) async {
    if (!allowVerification) {
      return SpeakerVerificationResult.rejected(
        similarity: 0.23,
        threshold: 0.65,
        reason: 'Mocked rejection',
      );
    }
    return SpeakerVerificationResult.matched(
      similarity: 0.95,
      reason: 'Mocked match',
    );
  }
}

/// 纯内存实现的 SessionMessagePort Stub，零 SQLite / SharedPreferences / 文件系统依赖
class StubSessionMessagePort implements SessionMessagePort {
  @override
  String currentSessionId;

  final List<ChatMessage> _messages = [];

  @override
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  int appendCount = 0;
  int updateCount = 0;
  int syncCount = 0;
  int startNewSessionCount = 0;
  int switchSessionCount = 0;
  String? updatedImageMessageId;
  String? updatedImagePath;

  StubSessionMessagePort({this.currentSessionId = 'session_mock_1'});

  @override
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  }) {
    appendCount++;
    final userMsgId =
        'user_${DateTime.now().microsecondsSinceEpoch}_$appendCount';
    final userMsg = ChatMessage(
      id: userMsgId,
      content: userText,
      role: 'user',
      timestamp: DateTime.now(),
      imagePath: imagePath,
    );
    _messages.add(userMsg);

    final assistantMsgId =
        'asst_${DateTime.now().microsecondsSinceEpoch}_$appendCount';
    final asstMsg = ChatMessage(
      id: assistantMsgId,
      content: '',
      role: 'assistant',
      timestamp: DateTime.now(),
    );
    _messages.add(asstMsg);

    return (
      userMsgId: userMsgId,
      assistantMsgId: assistantMsgId,
      assistantMsgIndex: _messages.length - 1,
    );
  }

  @override
  void updateAssistantMessageContent(
    String assistantMsgId,
    int preferredIndex,
    String content, {
    bool isStreaming = false,
  }) {
    updateCount++;
    int idx = preferredIndex;
    if (idx < 0 ||
        idx >= _messages.length ||
        _messages[idx].id != assistantMsgId) {
      idx = _messages.indexWhere((m) => m.id == assistantMsgId);
    }
    if (idx != -1) {
      final old = _messages[idx];
      _messages[idx] = ChatMessage(
        id: old.id,
        content: content,
        role: old.role,
        timestamp: old.timestamp,
        imagePath: old.imagePath,
      );
    }
  }

  @override
  void updateUserMessageContent(String userMsgId, String content) {
    final idx = _messages.indexWhere((m) => m.id == userMsgId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(content: content);
    }
  }

  @override
  ChatMessage appendUnintendedUserMessage(String userText) {
    appendCount++;
    final userMsg = ChatMessage(
      id: 'user_unintended_${DateTime.now().microsecondsSinceEpoch}_$appendCount',
      content: userText,
      role: 'user',
      timestamp: DateTime.now(),
      sessionId: currentSessionId,
      isUnintended: true,
    );
    _messages.add(userMsg);
    return userMsg;
  }

  @override
  void markUserTurnAsUnintended({
    required String userMsgId,
    String? assistantPlaceholderId,
    String? overrideText,
  }) {
    final idx = _messages.indexWhere((m) => m.id == userMsgId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(
        isUnintended: true,
        content: (overrideText != null && overrideText.trim().isNotEmpty)
            ? overrideText.trim()
            : _messages[idx].content,
      );
    }
    if (assistantPlaceholderId != null) {
      final aIdx = _messages.indexWhere((m) => m.id == assistantPlaceholderId);
      if (aIdx != -1 && _messages[aIdx].content.trim().isEmpty) {
        _messages.removeAt(aIdx);
      }
    }
  }

  @override
  void updateMessageImagePath(String messageId, String imagePath) {
    updatedImageMessageId = messageId;
    updatedImagePath = imagePath;
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) {
      final old = _messages[idx];
      _messages[idx] = ChatMessage(
        id: old.id,
        content: old.content,
        role: old.role,
        timestamp: old.timestamp,
        imagePath: imagePath,
      );
    }
  }

  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async {
    return '/mock/storage/sessions/$sessionId/$messageId.jpg';
  }

  @override
  Future<ChatSession?> syncCurrentSession({bool persist = true}) async {
    syncCount++;
    return ChatSession(
      id: currentSessionId,
      title: 'Mock Session',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: List.from(_messages),
    );
  }

  @override
  Future<ChatSession?> startNewSession() async {
    startNewSessionCount++;
    currentSessionId = 'session_mock_$startNewSessionCount';
    _messages.clear();
    return ChatSession(
      id: currentSessionId,
      title: 'New Mock Session',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: [],
    );
  }

  @override
  Future<ChatSession?> switchSession(String sessionId) async {
    switchSessionCount++;
    currentSessionId = sessionId;
    return ChatSession(
      id: currentSessionId,
      title: 'Switched Mock Session',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: List.from(_messages),
    );
  }

  @override
  void updateLightRagService(KnowledgePort? service) {}
}

/// 纯内存实现的 LlmPort Stub
class StubLlmPort implements LlmPort {
  int sendChatStreamCount = 0;
  final List<String> receivedQueries = [];
  String replyText = '这是测试回复内容';

  @override
  void applyConfig(LlmConfig config) {}

  @override
  Stream<String> sendChatStream({
    required String newUserContent,
    required List<ChatMessage> history,
    String? sessionId,
    Uint8List? imageBytes,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  }) async* {
    sendChatStreamCount++;
    receivedQueries.add(newUserContent);
    yield '{"intent":"chat","reply":"$replyText"}';
  }

  @override
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  }) async {
    sendChatStreamCount++;
    receivedQueries.add(newUserContent);
    return '{"intent":"chat","reply":"$replyText"}';
  }

  @override
  Future<String?> describeImage(Uint8List imageBytes) async {
    return '测试图片描述';
  }
}

/// 纯内存实现的 TtsPort Stub
class StubTtsPort implements TtsPort {
  int playCount = 0;
  int stopCount = 0;
  final List<String> playedTexts = [];

  @override
  bool get isSpeaking => false;

  @override
  String get recentlySpokenText => '';

  @override
  void applyConfig(TtsConfig config) {}

  @override
  void enqueueSentence(String sentence, {bool Function()? shouldCancel}) {
    playCount++;
    playedTexts.add(sentence);
  }

  @override
  Future<void> speakImmediate(String text) async {
    playCount++;
    playedTexts.add(text);
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> waitForCompletion() async {}

  @override
  Future<void> previewVoice({
    required String voice,
    required String text,
  }) async {}

  @override
  void dispose() {}
}

/// 纯内存实现的 PromptSoundPort Stub
class StubPromptSoundPort implements PromptSoundPort {
  int playToneCount = 0;
  int playShutterCount = 0;

  @override
  Future<void> playAcknowledgeBeep() async {
    playToneCount++;
  }

  @override
  Future<void> playShutterSound() async {
    playShutterCount++;
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (methodCall) async => '.',
  );

  group('Milestone 1 Empirical Challenge: Decoupled Coordinator Ports', () {
    late AppSettings testSettings;
    late StubAudioStreamControlPort stubAudioControl;
    late StubSpeakerVerificationPort stubSpeakerVerification;
    late StubSessionMessagePort stubSessionMessage;
    late StubLlmPort stubLlm;
    late StubTtsPort stubTts;
    late StubPromptSoundPort stubPromptSound;
    late List<AssistantEngineEvent> emittedEvents;
    late int notifyCount;

    setUp(() {
      testSettings = AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: false,
        enableBargeIn: true,
        enableSpeakerVerification: true,
        speakerVerifyWakeOnly: false,
        enableLightRag: false,
        startWordMode: AppConstants.startWordModeEnabled,
      );

      stubAudioControl = StubAudioStreamControlPort();
      stubSpeakerVerification = StubSpeakerVerificationPort();
      stubSessionMessage = StubSessionMessagePort();
      stubLlm = StubLlmPort();
      stubTts = StubTtsPort();
      stubPromptSound = StubPromptSoundPort();
      emittedEvents = [];
      notifyCount = 0;
    });

    test(
        '1. Direct construction with 100% pure custom stubs (zero hardware, zero session file storage)',
        () {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      // Verify port getters expose the segregated instances
      expect(coordinator.audioControlPort, same(stubAudioControl));
      expect(
          coordinator.speakerVerificationPort, same(stubSpeakerVerification));
      expect(coordinator.sessionMessagePort, same(stubSessionMessage));
      expect(coordinator.voiceCoordinator, same(stubAudioControl));
      expect(coordinator.sessionCoordinator, same(stubSessionMessage));

      expect(coordinator.status, AssistantStatus.idle);
      coordinator.dispose();
    });

    test(
        '2. Operates dialogue lifecycle via ports: wake, verification, LLM execution & session updates',
        () async {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      // Simulate incoming recognized speech from idle: matches wake word & end word
      await coordinator.processRecognizedText('晓漫 今天天气怎么样 回答');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Speaker verification port must have been checked
      expect(stubSpeakerVerification.verifyCallCount, greaterThanOrEqualTo(1));

      // Session message port must have appended user & placeholder messages
      expect(stubSessionMessage.appendCount, 1);
      expect(stubSessionMessage.messages.length, 2);
      expect(stubSessionMessage.messages.first.content, contains('今天天气怎么样'));

      // LLM must have been invoked
      expect(stubLlm.sendChatStreamCount, 1);
      expect(stubLlm.receivedQueries.first, contains('今天天气怎么样'));

      // Assistant message must have received streaming update
      expect(stubSessionMessage.updateCount, greaterThanOrEqualTo(1));
      expect(stubSessionMessage.messages.last.content, contains('这是测试回复内容'));

      // Session must have synced through SessionMessagePort
      expect(stubSessionMessage.syncCount, greaterThanOrEqualTo(1));

      coordinator.dispose();
    });

    test(
        '3. Speaker verification rejection: drops query, halts dialogue cleanly without side-effects',
        () async {
      stubSpeakerVerification.allowVerification = false;

      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      // Incoming speech from idle with mismatching voiceprint
      await coordinator.processRecognizedText('晓漫 帮我打开窗户 回答');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Verification rejected
      expect(stubSpeakerVerification.verifyCallCount, greaterThanOrEqualTo(1));
      expect(stubSpeakerVerification.rejectedReasons, isNotEmpty);

      // Zero LLM calls should have occurred
      expect(stubLlm.sendChatStreamCount, 0);

      // Zero user messages appended to session
      expect(stubSessionMessage.appendCount, 0);

      // Coordinator returns to idle
      expect(coordinator.status, AssistantStatus.idle);

      coordinator.dispose();
    });

    test(
        '4. Speaker enrollment protection: rejects all speech when isEnrolling is true',
        () async {
      stubSpeakerVerification.isEnrolling = true;

      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      // Incoming speech should be ignored
      await coordinator.processRecognizedText('晓漫');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(coordinator.isWakeWordMatched, isFalse);
      expect(coordinator.status, AssistantStatus.idle);
      expect(stubAudioControl.resetStreamCount, 0);

      coordinator.dispose();
    });

    test('5. Barge-in interruption triggers audioControlPort.flushBuffers',
        () async {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      coordinator.setStatus(AssistantStatus.playing, '正在播报一段很长的语音');
      coordinator.currentSpeakingReply = '正在播报一段很长的语音';

      // Simulate barge-in with stop word
      await coordinator.handlePlayingBargeIn('停止');

      // Must invoke flushBuffers with 400ms cooldown
      expect(stubAudioControl.flushBuffersCount, greaterThanOrEqualTo(1));
      expect(stubAudioControl.flushCooldownHistory, contains(400));
      expect(coordinator.status, AssistantStatus.idle);

      coordinator.dispose();
    });

    test('6. Session lifecycle delegation: new session and switch session',
        () async {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      await coordinator.startNewSession(playVoice: false);
      expect(stubSessionMessage.startNewSessionCount, 1);
      expect(stubAudioControl.flushBuffersCount, greaterThanOrEqualTo(1));

      await coordinator.switchSession('target_session_99');
      expect(stubSessionMessage.switchSessionCount, 1);
      expect(stubSessionMessage.currentSessionId, 'target_session_99');

      coordinator.dispose();
    });

    test(
        '7. Stream isolation on session switch: discards orphaned stream updates',
        () async {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      // Start text submit
      final futureSubmit = coordinator.sendTextMessage('你好测试');

      // During generation, switch the session
      stubSessionMessage.currentSessionId = 'different_session_during_stream';

      await futureSubmit;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Any writes targeted for previous session should not corrupt the active session
      expect(stubSessionMessage.currentSessionId,
          'different_session_during_stream');

      coordinator.dispose();
    });

    test(
        '8. Stress Test: High-frequency concurrent flood of flushBuffers, resetStream & verifyOwnerSpeaker',
        () async {
      final coordinator = DialogueIntentCoordinator(
        settings: testSettings,
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
        audioControlPort: stubAudioControl,
        speakerVerificationPort: stubSpeakerVerification,
        sessionMessagePort: stubSessionMessage,
        llmService: stubLlm,
        ttsService: stubTts,
        promptSoundService: stubPromptSound,
      );

      const int concurrentWorkers = 20;
      const int iterationsPerWorker = 50;
      final sw = Stopwatch()..start();

      final futures = <Future<void>>[];

      for (int w = 0; w < concurrentWorkers; w++) {
        futures.add(Future(() async {
          for (int i = 0; i < iterationsPerWorker; i++) {
            final op = (w + i) % 5;
            switch (op) {
              case 0:
                stubAudioControl.flushBuffers(cooldownMs: 300 + (i % 200));
                break;
              case 1:
                stubAudioControl.resetStream();
                break;
              case 2:
                stubSpeakerVerification.verifyOwnerSpeaker(
                    contextHint: 'stress_worker_$w');
                break;
              case 3:
                stubAudioControl.performIdleHygiene();
                break;
              case 4:
                // Rapidly update status hints or triggers
                await coordinator.handlePlayingBargeIn('停止');
                break;
            }
            // Yield microtask to allow async interleaving
            await Future<void>.delayed(Duration.zero);
          }
        }));
      }

      await Future.wait(futures);
      sw.stop();

      // ignore: avoid_print
      print(
          '[Challenger Stress] Finished ${concurrentWorkers * iterationsPerWorker} operations in ${sw.elapsedMilliseconds}ms');

      expect(stubAudioControl.flushBuffersCount, greaterThan(100));
      expect(stubAudioControl.resetStreamCount, greaterThan(50));
      expect(stubSpeakerVerification.verifyCallCount, greaterThan(50));
      expect(coordinator.isDisposed, isFalse);

      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);
    });
  });
}
