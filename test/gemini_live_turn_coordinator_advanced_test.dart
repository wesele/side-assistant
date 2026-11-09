import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_barge_in_controller.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_state_machine.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/gemini_live_turn_coordinator.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/transcript_trigger_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/assistant_status.dart';
import 'package:side_assistant/core/models/camera_capture_result.dart';
import 'package:side_assistant/core/ports/audio_stream_control_port.dart';
import 'package:side_assistant/core/ports/gemini_live_session_port.dart';
import 'package:side_assistant/core/ports/prompt_sound_port.dart';
import 'package:side_assistant/core/ports/session_message_port.dart';
import 'package:side_assistant/core/ports/speaker_verification_port.dart';
import 'package:side_assistant/core/ports/trigger_matcher_port.dart';
import 'package:side_assistant/core/ports/tts_port.dart';

class _FakeLiveSessionPort extends NullGeminiLiveSessionPort {
  bool _isAdvanced;
  bool _isSpeakingOutput = false;

  _FakeLiveSessionPort({bool isAdvanced = true}) : _isAdvanced = isAdvanced;

  @override
  bool get isAdvancedMode => _isAdvanced;

  set isAdvancedMode(bool val) => _isAdvanced = val;

  @override
  bool get isSpeakingOutput => _isSpeakingOutput;

  set isSpeakingOutput(bool val) => _isSpeakingOutput = val;
}

class _TestSessionMessagePort implements SessionMessagePort {
  @override
  String currentSessionId = 'test_session_id';
  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<String> persistedImagePaths = <String>[];
  int syncCount = 0;
  bool? lastIsStreaming;

  @override
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  @override
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  }) {
    final userMsg = ChatMessage(
      id: 'user_${_messages.length + 1}',
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      imagePath: imagePath,
    );
    final asstMsg = ChatMessage(
      id: 'asst_${_messages.length + 2}',
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
    );
    _messages.add(userMsg);
    _messages.add(asstMsg);
    return (
      userMsgId: userMsg.id,
      assistantMsgId: asstMsg.id,
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
    lastIsStreaming = isStreaming;
    final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(content: content);
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
    final msg = ChatMessage(
      id: 'unintended_${_messages.length + 1}',
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      isUnintended: true,
    );
    _messages.add(msg);
    return msg;
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
        content: overrideText ?? _messages[idx].content,
      );
    }
    if (assistantPlaceholderId != null) {
      _messages.removeWhere((m) => m.id == assistantPlaceholderId);
    }
  }

  @override
  void updateMessageImagePath(String messageId, String imagePath) {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(imagePath: imagePath);
    }
  }

  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async {
    final p = sourcePath ?? 'persisted_img_$messageId.jpg';
    persistedImagePaths.add(p);
    return p;
  }

  @override
  Future<ChatSession?> syncCurrentSession({bool persist = false}) async {
    syncCount++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPromptSoundPort implements PromptSoundPort {
  int shutterCount = 0;
  @override
  Future<void> playShutterSound() async => shutterCount++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestAudioControlPort implements AudioStreamControlPort {
  @override
  bool get isMicListening => false;
  @override
  bool get isAsrStreaming => false;
  @override
  void performIdleHygiene() {}
  @override
  void resetStream() {}
  @override
  void flushBuffers({int cooldownMs = 600}) {}
}

class _TestSpeakerVerificationPort implements SpeakerVerificationPort {
  @override
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) =>
      true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestTriggerMatcherPort implements TriggerMatcherPort {
  @override
  List<String> get startWords => const ['小曼'];
  @override
  Future<TriggerMatchResult> checkStartWord(String text) async =>
      TriggerMatchResult.none();
  @override
  Future<TriggerMatchResult> checkEndWord(String text) async =>
      TriggerMatchResult.none();
  @override
  Future<TriggerMatchResult> checkResetWord(String text) async =>
      TriggerMatchResult.none();
  @override
  Future<bool> checkExitContinuousWord(String text) async => false;
  @override
  Future<ExtractedCommand?> extractOneShotCommand(String text) async => null;
  @override
  String stripPunctuation(String text, {bool all = false}) => text;
  @override
  String stripEndWord(String text) => text;
  @override
  void warmUp() {}
}

class _TestTtsPort extends NoopTtsPort {
  final List<String> spokenTexts = <String>[];
  int stopCalls = 0;

  @override
  Future<void> speakImmediate(String text) async {
    spokenTexts.add(text);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings settings;
  late _FakeLiveSessionPort liveSession;
  late _TestSessionMessagePort sessionMessagePort;
  late _TestPromptSoundPort promptSoundPort;
  late _TestAudioControlPort audioControlPort;
  late _TestTtsPort ttsPort;
  late DialogueStateMachine stateMachine;
  late TranscriptTriggerCoordinator transcriptCoordinator;
  final events = <AssistantEngineEvent>[];
  var notifyCount = 0;

  GeminiLiveTurnCoordinator createCoordinator({
    bool isAdvanced = true,
    Duration toolProgressInterval = const Duration(milliseconds: 50),
    Duration deferredTimeout = const Duration(seconds: 90),
    Future<CameraCaptureResult> Function()? onCapturePhotoDirect,
    void Function(String thought)? onThoughtSummary,
  }) {
    liveSession = _FakeLiveSessionPort(isAdvanced: isAdvanced);
    sessionMessagePort = _TestSessionMessagePort();
    promptSoundPort = _TestPromptSoundPort();
    audioControlPort = _TestAudioControlPort();
    ttsPort = _TestTtsPort();

    stateMachine = DialogueStateMachine(
      settings: settings,
      audioControlPort: audioControlPort,
      ttsService: ttsPort,
      hasSessionMessages: () => sessionMessagePort.messages.isNotEmpty,
      onNotify: () => notifyCount++,
    );

    final speakerVerification = _TestSpeakerVerificationPort();
    final triggerMatcher = _TestTriggerMatcherPort();

    final bargeInController = DialogueBargeInController(
      settings: settings,
      audioControlPort: audioControlPort,
      speakerVerificationPort: speakerVerification,
      ttsService: ttsPort,
      triggerMatcher: triggerMatcher,
    );

    transcriptCoordinator = TranscriptTriggerCoordinator(
      settings: settings,
      emit: events.add,
      onNotify: () => notifyCount++,
      audioControlPort: audioControlPort,
      speakerVerificationPort: speakerVerification,
      triggerMatcher: triggerMatcher,
      ttsService: ttsPort,
      stateMachine: stateMachine,
      bargeInController: bargeInController,
      onSubmitLlm: (text, {required isExplicitCommand}) async {},
    );

    return GeminiLiveTurnCoordinator(
      settings: settings,
      emit: events.add,
      onNotify: () => notifyCount++,
      sessionMessagePort: sessionMessagePort,
      promptSoundService: promptSoundPort,
      stateMachine: stateMachine,
      transcriptCoordinator: transcriptCoordinator,
      onCapturePhotoDirect: onCapturePhotoDirect,
      onSpeakStatus: (text) => ttsPort.speakImmediate(text),
      onStopSpeakStatus: () => ttsPort.stop(),
      toolProgressInterval: toolProgressInterval,
      deferredTurnTimeout: deferredTimeout,
      onThoughtSummary: onThoughtSummary,
      liveSession: liveSession,
    );
  }

  setUp(() {
    events.clear();
    notifyCount = 0;
    settings = AppSettings(
      pipelineMode: AppConstants.pipelineModeGeminiLive,
      geminiApiKey: 'test_key',
      geminiLiveModel: 'gemini-3.8-live',
    );
  });

  group('GeminiLiveTurnCoordinator Advanced Mode Dual-Mode Tests', () {
    test('1. Basic Mode: turnComplete immediately resets turn tracking',
        () async {
      final coordinator = createCoordinator(isAdvanced: false);
      addTearDown(coordinator.dispose);

      // User speaks
      liveSession.onInputTranscription?.call('你好小曼', isFinal: true);
      expect(sessionMessagePort.messages.length, equals(2));
      expect(sessionMessagePort.messages.first.content, equals('你好小曼'));

      // Model starts and speaks
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription?.call('你好！', '你好！', isFinal: true);
      expect(sessionMessagePort.messages[1].content, equals('你好！'));

      // Even if interactionStatus is inProgress, basic mode ignores it on turnComplete
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isFalse);

      // Subsequent input creates a NEW turn
      liveSession.onInputTranscription?.call('第二句话', isFinal: true);
      expect(sessionMessagePort.messages.length, equals(4));
      expect(sessionMessagePort.messages[2].content, equals('第二句话'));
    });

    test(
        '2. Advanced Mode: turnComplete during inProgress keeps single user bubble and appends assistant bubble',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      // 1. User asks question
      liveSession.onInputTranscription?.call('请帮我看看这张图并分析天气', isFinal: true);
      expect(sessionMessagePort.messages.length, equals(2));
      final originalUserMsgId = sessionMessagePort.messages[0].id;
      final originalAsstMsgId = sessionMessagePort.messages[1].id;

      // 2. Model outputs first segment: "好的，我先看一下画面。"
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription
          ?.call('好的，我先看一下画面。', '好的，我先看一下画面。', isFinal: true);
      expect(sessionMessagePort.messages[1].content, equals('好的，我先看一下画面。'));

      // 3. interactionStatus = true (IN_PROGRESS)
      liveSession.onInteractionStatus?.call(true);
      expect(coordinator.lastInteractionInProgress, isTrue);

      // 4. First segment turnComplete arrives -> should be deferred!
      liveSession.onTurnCompleted?.call();
      expect(coordinator.isTurnDeferred, isTrue);
      expect(sessionMessagePort.messages.length, equals(2));
      expect(sessionMessagePort.messages[1].content, equals('好的，我先看一下画面。'));

      // 5. Subsequent model turn starts (second segment)
      liveSession.onModelTurnStarted?.call();
      // Should NOT have created a fake （语音输入） bubble!
      expect(sessionMessagePort.messages.length, equals(2));
      expect(sessionMessagePort.messages[0].id, equals(originalUserMsgId));
      expect(sessionMessagePort.messages[0].content, equals('请帮我看看这张图并分析天气'));

      // 6. Model streams second segment: "画面显示晴空万里，微风习习。"
      liveSession.onOutputTranscription
          ?.call('画面显示晴空万里，微风习习。', '画面显示晴空万里，微风习习。', isFinal: true);

      // Combined into the SAME assistant bubble (newline-separated)
      expect(sessionMessagePort.messages.length, equals(2));
      expect(sessionMessagePort.messages[1].id, equals(originalAsstMsgId));
      expect(
        sessionMessagePort.messages[1].content,
        equals('好的，我先看一下画面。\n画面显示晴空万里，微风习习。'),
      );
    });

    test('3. Advanced Mode: IDLE interactionStatus resets deferred turn',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      // Turn 1 setup
      liveSession.onInputTranscription?.call('查询股价', isFinal: true);
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription
          ?.call('正在查询...', '正在查询...', isFinal: true);
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);

      // Server emits IDLE (inProgress = false) while deferred and speaking is done
      liveSession.onInteractionStatus?.call(false);
      expect(coordinator.isTurnDeferred, isFalse);
      expect(coordinator.lastInteractionInProgress, isFalse);

      // Next user utterance now correctly starts a brand new turn
      liveSession.onInputTranscription?.call('另一个问题', isFinal: true);
      expect(sessionMessagePort.messages.length, equals(4));
      expect(sessionMessagePort.messages[2].content, equals('另一个问题'));
    });

    test('4. Advanced Mode: Safety timeout resets deferred turn', () async {
      final coordinator = createCoordinator(
        isAdvanced: true,
        deferredTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(coordinator.dispose);

      liveSession.onInputTranscription?.call('长耗时提问', isFinal: true);
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription?.call('稍等...', '稍等...', isFinal: true);
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);
      expect(coordinator.isDeferredTimerActive, isTrue);

      // Wait for the safety timeout (30ms) to fire
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(coordinator.isTurnDeferred, isFalse);
      expect(coordinator.isDeferredTimerActive, isFalse);

      // New user utterance creates a new pair of bubbles
      liveSession.onInputTranscription?.call('超时后的新问题', isFinal: true);
      expect(sessionMessagePort.messages.length, equals(4));
      expect(sessionMessagePort.messages[2].content, equals('超时后的新问题'));
    });

    test(
        '5. Advanced Mode: New user speech while deferred resets previous turn',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      liveSession.onInputTranscription?.call('第 1 问', isFinal: true);
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription?.call('答复 1', '答复 1', isFinal: true);
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);

      // User starts speaking a genuinely new turn
      liveSession.onInputTranscription?.call('第 2 问', isFinal: true);

      // Deferred turn was reset and new messages created
      expect(coordinator.isTurnDeferred, isFalse);
      expect(sessionMessagePort.messages.length, equals(4));
      expect(sessionMessagePort.messages[2].content, equals('第 2 问'));
    });

    test('6. Local TTS suppression in Advanced mode vs Basic mode', () async {
      // 6.1 Basic Mode: calls onSpeakStatus (initial & periodic heartbeat)
      final basicCoord = createCoordinator(
        isAdvanced: false,
        toolProgressInterval: const Duration(milliseconds: 30),
      );
      addTearDown(basicCoord.dispose);

      liveSession.onInputTranscription?.call('写个工具', isFinal: true);
      liveSession.onToolCall?.call('invoke_opencode', '计算器');

      // Basic mode invokes initial onSpeakStatus
      expect(ttsPort.spokenTexts, isNotEmpty);
      expect(ttsPort.spokenTexts.first, contains('计算器'));

      // Wait for at least one heartbeat tick
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ttsPort.spokenTexts.length, greaterThan(1));
      basicCoord.dispose();

      // 6.2 Advanced Mode: suppresses local TTS completely
      final advCoord = createCoordinator(
        isAdvanced: true,
        toolProgressInterval: const Duration(milliseconds: 30),
      );
      addTearDown(advCoord.dispose);

      ttsPort.spokenTexts.clear();
      liveSession.onInputTranscription?.call('写个工具', isFinal: true);
      liveSession.onToolCall?.call('invoke_opencode', '计算器');

      // Advanced mode: NO spoken texts generated!
      expect(ttsPort.spokenTexts, isEmpty);

      // Wait for heartbeat tick: UI updates but NO TTS!
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ttsPort.spokenTexts, isEmpty);

      // But assistant bubble was updated with progress
      expect(
        sessionMessagePort.messages.last.content,
        contains('编写并调试'),
      );
    });

    test('7. Cancellation clears heartbeat timer, tracking and updates UI',
        () async {
      final coordinator = createCoordinator(
        isAdvanced: true,
        toolProgressInterval: const Duration(milliseconds: 40),
      );
      addTearDown(coordinator.dispose);

      coordinator.trackPendingToolCall('call_abc');
      expect(coordinator.pendingToolCallIds, contains('call_abc'));

      liveSession.onInputTranscription?.call('执行复杂脚本', isFinal: true);
      liveSession.onToolCall?.call('invoke_opencode', '爬虫脚本');

      expect(coordinator.isToolProgressRunning, isTrue);

      // Cancel the tool call
      liveSession.onToolCallsCancelled?.call(['call_abc']);

      // 1. Heartbeat timer is cancelled
      expect(coordinator.isToolProgressRunning, isFalse);

      // 2. Tracking for that id is cleared
      expect(coordinator.pendingToolCallIds, isNot(contains('call_abc')));

      // 3. UI status reflects cancellation
      expect(stateMachine.statusHint, equals('工具调用已取消'));
      expect(
        sessionMessagePort.messages.last.content,
        contains('工具调用已取消'),
      );
    });

    test(
        '8. Thoughts routing: onThought routes to summary without polluting chat',
        () async {
      String? capturedThought;
      final coordinator = createCoordinator(
        isAdvanced: true,
        onThoughtSummary: (t) => capturedThought = t,
      );
      addTearDown(coordinator.dispose);

      liveSession.onInputTranscription?.call('量子物理问题', isFinal: true);
      liveSession.onThought?.call('思考中：分析薛定谔方程...');

      expect(capturedThought, equals('思考中：分析薛定谔方程...'));
      expect(stateMachine.statusHint, contains('正在思考'));

      // Ensure thought text does NOT appear in chat messages
      for (final msg in sessionMessagePort.messages) {
        expect(msg.content, isNot(contains('分析薛定谔方程')));
      }
    });

    test('9. Captured photo association preserved across deferred turn',
        () async {
      final coordinator = createCoordinator(
        isAdvanced: true,
        onCapturePhotoDirect: () async => CameraCaptureResult(
          filePath: '/tmp/test_photo.jpg',
          imageBytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      addTearDown(coordinator.dispose);

      liveSession.onInputTranscription?.call('看看这个杯子', isFinal: true);
      await liveSession.onCapturePhoto?.call();

      expect(sessionMessagePort.messages.first.imagePath,
          equals('/tmp/test_photo.jpg'));

      // First segment finishes and defers
      liveSession.onOutputTranscription?.call('我看到了。', '我看到了。', isFinal: true);
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);

      // Image association still maintained during deferred turn
      expect(sessionMessagePort.messages.first.imagePath,
          equals('/tmp/test_photo.jpg'));

      // Finalize deferred turn
      liveSession.onInteractionStatus?.call(false);
      expect(coordinator.isTurnDeferred, isFalse);
      expect(sessionMessagePort.persistedImagePaths,
          contains('/tmp/test_photo.jpg'));
    });

    test(
        '10. Interruption resets lastInteractionInProgress to prevent stale flag from falsely deferring next turn',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      // Turn 1 starts and receives inProgress=true
      liveSession.onInputTranscription?.call('第一轮开始', isFinal: true);
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription
          ?.call('正在输出一些很长的话...', '正在输出一些很长的话...', isFinal: false);
      liveSession.onInteractionStatus?.call(true);
      expect(coordinator.lastInteractionInProgress, isTrue);

      // User interrupts
      liveSession.onInterrupted?.call();

      // Interruption must reset lastInteractionInProgress to false!
      expect(coordinator.lastInteractionInProgress, isFalse);
      expect(coordinator.isTurnDeferred, isFalse);

      // Turn 2: genuine new turn with no new inProgress signal
      liveSession.onInputTranscription?.call('第二轮正常提问', isFinal: true);
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription
          ?.call('正常简短回答', '正常简短回答', isFinal: true);
      liveSession.onTurnCompleted?.call();

      // Must NOT falsely defer!
      expect(coordinator.isTurnDeferred, isFalse);
    });

    test(
        '11. _handleInteractionStatus(false) must not end deferred turn while tool calls remain pending',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      coordinator.trackPendingToolCall('tool_running_1');
      liveSession.onInputTranscription?.call('触发后台工具', isFinal: true);
      liveSession.onTurnCompleted?.call();

      // Turn is deferred because tool_running_1 is pending
      expect(coordinator.isTurnDeferred, isTrue);

      // Server sends IDLE (false)
      liveSession.onInteractionStatus?.call(false);

      // Turn must STILL be deferred because tool_running_1 is still pending!
      expect(coordinator.isTurnDeferred, isTrue);

      // Now tool finishes normally
      coordinator.removePendingToolCall('tool_running_1');

      // Now deferred turn ends cleanly!
      expect(coordinator.isTurnDeferred, isFalse);
      expect(stateMachine.status, equals(AssistantStatus.listeningContent));
    });

    test(
        '12. Tool cancellation ends deferred turn if interactionStatus is already idle and no other tools pending',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      coordinator.trackPendingToolCall('tool_cancel_me');
      liveSession.onInputTranscription?.call('要被取消的工具', isFinal: true);
      liveSession.onToolCall?.call('invoke_opencode', '复杂编译任务');
      liveSession.onInteractionStatus?.call(false);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);

      // Server cancels the tool call
      liveSession.onToolCallsCancelled?.call(['tool_cancel_me']);

      // Cancellation triggers _maybeEndDeferredTurn and cleanly ends deferred turn
      expect(coordinator.isTurnDeferred, isFalse);
      expect(coordinator.pendingToolCallIds, isEmpty);
      expect(stateMachine.status, equals(AssistantStatus.listeningContent));
    });

    test(
        '13. _markTurnDeferred preserves in-flight tool status and sets isStreaming=true until final end',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      liveSession.onInputTranscription?.call('拍照指令', isFinal: true);
      // Tool status update before any assistant reply text
      liveSession.onToolCall?.call('capture_photo', '');
      expect(sessionMessagePort.messages.last.content, equals('正在调用相机拍照...'));

      // Model turn complete with inProgress=true before any model speech
      liveSession.onInteractionStatus?.call(true);
      liveSession.onTurnCompleted?.call();

      expect(coordinator.isTurnDeferred, isTrue);
      // Bubble must NOT be overwritten with empty text!
      expect(sessionMessagePort.messages.last.content, equals('正在调用相机拍照...'));

      // Model answers in next segment
      liveSession.onModelTurnStarted?.call();
      liveSession.onOutputTranscription
          ?.call('我看到了一本书。', '我看到了一本书。', isFinal: true);
      // Deferred turn complete
      liveSession.onTurnCompleted?.call();
      liveSession.onInteractionStatus?.call(false);

      // Turn ends: final text and isStreaming becomes false
      expect(coordinator.isTurnDeferred, isFalse);
      expect(sessionMessagePort.messages.last.content, contains('我看到了一本书。'));
      expect(sessionMessagePort.lastIsStreaming, isFalse);
    });

    test(
        '14. onThought thinking state is cleared when model starts speaking or deferred turn ends',
        () async {
      final coordinator = createCoordinator(isAdvanced: true);
      addTearDown(coordinator.dispose);

      // 14.1 Cleared when model starts speaking
      liveSession.onInputTranscription?.call('问题 A', isFinal: true);
      liveSession.onThought?.call('正在深度推理 A...');
      expect(stateMachine.status, equals(AssistantStatus.thinking));

      liveSession.onModelTurnStarted?.call();
      expect(stateMachine.status, equals(AssistantStatus.playing));

      liveSession.onOutputTranscription?.call('回答 A', '回答 A', isFinal: true);
      liveSession.onInteractionStatus?.call(false);
      liveSession.onTurnCompleted?.call();

      // 14.2 Cleared when deferred turn ends
      liveSession.onInputTranscription?.call('问题 B', isFinal: true);
      coordinator.trackPendingToolCall('b_tool');
      liveSession.onTurnCompleted?.call();
      expect(coordinator.isTurnDeferred, isTrue);

      // Thought arrives during deferred state
      liveSession.onThought?.call('正在深度推理 B...');
      expect(stateMachine.status, equals(AssistantStatus.thinking));

      // Tool completes and ends deferred turn -> thinking is cleared to listeningContent
      coordinator.removePendingToolCall('b_tool');
      expect(coordinator.isTurnDeferred, isFalse);
      expect(stateMachine.status, equals(AssistantStatus.listeningContent));
    });
  });
}
