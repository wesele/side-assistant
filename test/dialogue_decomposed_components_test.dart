import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_barge_in_controller.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_llm_orchestrator.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_state_machine.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/streaming_sentence_segmenter.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/transcript_trigger_coordinator.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/assistant_status.dart';
import 'package:side_assistant/core/models/camera_capture_result.dart';
import 'package:side_assistant/core/ports/audio_stream_control_port.dart';
import 'package:side_assistant/core/ports/llm_port.dart';
import 'package:side_assistant/core/ports/prompt_sound_port.dart';
import 'package:side_assistant/core/ports/session_message_port.dart';
import 'package:side_assistant/core/ports/speaker_verification_port.dart';
import 'package:side_assistant/core/ports/trigger_matcher_port.dart';
import 'package:side_assistant/core/ports/tts_port.dart';

class MockAudioControlPort implements AudioStreamControlPort {
  @override
  bool isMicListening = true;
  @override
  bool isAsrStreaming = true;

  int idleHygieneCount = 0;
  int resetStreamCount = 0;
  int flushBuffersCount = 0;
  int lastCooldownMs = 0;

  @override
  void performIdleHygiene() => idleHygieneCount++;

  @override
  void resetStream() => resetStreamCount++;

  @override
  void flushBuffers({int cooldownMs = 600}) {
    flushBuffersCount++;
    lastCooldownMs = cooldownMs;
  }
}

class MockSpeakerVerificationPort implements SpeakerVerificationPort {
  @override
  bool isEnrolling = false;
  bool allowVerification = true;
  int verifyCount = 0;

  @override
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) {
    verifyCount++;
    if (!allowVerification) {
      onRejected?.call('声纹不匹配');
      return false;
    }
    return true;
  }

  @override
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  }) async {
    return allowVerification
        ? SpeakerVerificationResult.matched(similarity: 0.95, reason: 'ok')
        : SpeakerVerificationResult.rejected(
            similarity: 0.3,
            threshold: 0.65,
            reason: 'low similarity',
          );
  }
}

class MockTtsPort implements TtsPort {
  final List<String> spokenSentences = [];
  final List<String> enqueuedSentences = [];
  bool isSpeakingValue = false;
  String recentlySpokenTextValue = '';

  @override
  bool get isSpeaking => isSpeakingValue;

  @override
  String get recentlySpokenText => recentlySpokenTextValue;

  @override
  Future<void> speakImmediate(String text) async {
    spokenSentences.add(text);
    recentlySpokenTextValue = text;
  }

  @override
  void enqueueSentence(String sentence, {bool Function()? shouldCancel}) {
    if (shouldCancel?.call() ?? false) return;
    enqueuedSentences.add(sentence);
  }

  @override
  Future<void> waitForCompletion() async {}

  @override
  Future<void> stop() async {
    isSpeakingValue = false;
  }

  @override
  Future<void> previewVoice(
      {required String voice, required String text}) async {}

  @override
  void applyConfig(dynamic config) {}

  @override
  void dispose() {}
}

class MockTriggerMatcherPort implements TriggerMatcherPort {
  String startWord = '小曼';
  String endWord = '回答';

  @override
  List<String> get startWords => [startWord];

  @override
  Future<TriggerMatchResult> checkStartWord(String text) async {
    if (text.contains(startWord)) {
      final idx = text.indexOf(startWord);
      return TriggerMatchResult(
        type: TriggerType.start,
        matchedText: startWord,
        similarity: 1.0,
        method: 'exact',
        startIndex: idx,
        endIndex: idx + startWord.length,
      );
    }
    return TriggerMatchResult.none();
  }

  @override
  Future<TriggerMatchResult> checkEndWord(String text) async {
    if (text.contains(endWord)) {
      final idx = text.indexOf(endWord);
      return TriggerMatchResult(
        type: TriggerType.end,
        matchedText: endWord,
        similarity: 1.0,
        method: 'exact',
        startIndex: idx,
        endIndex: idx + endWord.length,
      );
    }
    return TriggerMatchResult.none();
  }

  @override
  Future<TriggerMatchResult> checkResetWord(String text) async {
    if (text.contains('新起一个')) {
      final idx = text.indexOf('新起一个');
      return TriggerMatchResult(
        type: TriggerType.reset,
        matchedText: '新起一个',
        similarity: 1.0,
        method: 'exact',
        startIndex: idx,
        endIndex: idx + 4,
      );
    }
    return TriggerMatchResult.none();
  }

  @override
  Future<bool> checkExitContinuousWord(String text) async {
    return text.contains('退出') || text.contains('结束对话');
  }

  @override
  Future<ExtractedCommand?> extractOneShotCommand(String text) async {
    if (text.startsWith(startWord) && text.length > startWord.length) {
      final cmd = text.substring(startWord.length).trim();
      if (cmd.isNotEmpty && !cmd.contains(endWord)) {
        return ExtractedCommand(
          startWord: startWord,
          promptContent: cmd,
          endWord: '',
        );
      }
    }
    return null;
  }

  @override
  String stripPunctuation(String text, {bool all = false}) {
    return text.replaceAll(RegExp(r'[，。！？,\.!?\s]'), '');
  }

  @override
  String stripEndWord(String text) {
    return text.replaceAll(endWord, '').trim();
  }

  @override
  void warmUp() {}
}

class MockSessionMessagePort implements SessionMessagePort {
  @override
  String currentSessionId = 'test_session_1';
  final List<ChatMessage> _messages = [];

  @override
  List<ChatMessage> get messages => _messages;

  @override
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  }) {
    _messages.add(ChatMessage(
      id: 'user_1',
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      imagePath: imagePath,
    ));
    _messages.add(ChatMessage(
      id: 'asst_1',
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
    ));
    return (
      userMsgId: 'user_1',
      assistantMsgId: 'asst_1',
      assistantMsgIndex: 1,
    );
  }

  @override
  void updateAssistantMessageContent(
    String assistantMsgId,
    int preferredIndex,
    String content, {
    bool isStreaming = false,
  }) {
    if (preferredIndex < _messages.length) {
      _messages[preferredIndex] = ChatMessage(
        id: assistantMsgId,
        role: 'assistant',
        content: content,
        timestamp: DateTime.now(),
      );
    }
  }

  @override
  void updateMessageImagePath(String messageId, String imagePath) {}

  @override
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  }) async =>
      sourcePath ?? 'persisted/image.png';

  @override
  Future<ChatSession?> syncCurrentSession({bool persist = true}) async => null;

  @override
  Future<ChatSession?> startNewSession() async => null;

  @override
  Future<ChatSession?> switchSession(String sessionId) async => null;

  @override
  void updateLightRagService(dynamic service) {}
}

class MockLlmPort implements LlmPort {
  int callCount = 0;
  String replyStreamJson = '{"intent":"chat","reply":"测试回复。"}';

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
    yield replyStreamJson;
  }

  @override
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  }) async =>
      replyStreamJson;

  @override
  Future<String?> describeImage(Uint8List imageBytes, {String? prompt}) async =>
      '图片描述';

  @override
  void applyConfig(LlmConfig config) {}
}

class MockPromptSoundPort implements PromptSoundPort {
  int beepCount = 0;
  int shutterCount = 0;

  @override
  Future<void> playAcknowledgeBeep() async => beepCount++;

  @override
  Future<void> playShutterSound() async => shutterCount++;

  @override
  void dispose() {}
}

void main() {
  AppSettings buildSettings() => AppSettings(
        startWord: '小曼',
        endWord: '回答',
        resetWord: '新起一个',
        audio: const AudioConfig(
          startWord: '小曼',
          endWord: '回答',
          resetWord: '新起一个',
          exitContinuousWord: '退下吧,再见',
        ),
        enableBargeIn: true,
        enableTtsPlayback: true,
        silenceTimeoutSeconds: 5,
        startWordMode: AppConstants.startWordModeEnabled,
      );

  group('DialogueStateMachine Tests', () {
    test('1. 初始状态与提示文案计算', () {
      final audio = MockAudioControlPort();
      final sm = DialogueStateMachine(
        settings: buildSettings(),
        audioControlPort: audio,
      );

      expect(sm.status, equals(AssistantStatus.idle));
      expect(sm.isInContinuousMode, isFalse);
      expect(sm.statusShortLabel, equals('待机'));

      // 麦克风关闭时自动修正提示
      audio.isMicListening = false;
      sm.setStatus(AssistantStatus.idle, '待机中，可说“小曼”随时呼唤');
      expect(sm.statusHint, contains('话筒未开启'));
    });

    test('2. 状态跃迁与回调触发', () {
      AssistantStatus? oldS;
      AssistantStatus? newS;
      String? updatedHint;
      int notifyCount = 0;

      final sm = DialogueStateMachine(
        settings: buildSettings(),
        onStatusChanged: (o, n, h) {
          oldS = o;
          newS = n;
          updatedHint = h;
        },
        onNotify: () => notifyCount++,
      );

      sm.setStatus(AssistantStatus.listeningContent, '正在倾听');
      expect(oldS, equals(AssistantStatus.idle));
      expect(newS, equals(AssistantStatus.listeningContent));
      expect(updatedHint, equals('正在倾听'));
      expect(notifyCount, equals(1));
    });

    test('3. 连续对话生命周期与退出', () async {
      final settings = buildSettings()
        ..startWordMode = AppConstants.startWordModeAuto;
      final audio = MockAudioControlPort();
      final tts = MockTtsPort();
      bool? continuousMode;

      final sm = DialogueStateMachine(
        settings: settings,
        audioControlPort: audio,
        ttsService: tts,
        onContinuousModeChanged: (val, reason) => continuousMode = val,
      );

      sm.enterContinuousMode();
      expect(sm.isInContinuousMode, isTrue);
      expect(continuousMode, isTrue);

      await sm.exitContinuousMode(byUser: true);
      expect(sm.isInContinuousMode, isFalse);
      expect(continuousMode, isFalse);
      expect(audio.flushBuffersCount, greaterThan(0));
      expect(tts.spokenSentences, isNotEmpty);
    });

    test('4. 静音超时计时器触发', () async {
      bool timedOut = false;
      final sm = DialogueStateMachine(
        settings: buildSettings(),
        onSilenceTimeout: () async {
          timedOut = true;
        },
      );

      sm.setStatus(AssistantStatus.listeningContent, '倾听中');
      sm.startSilenceTimer(
        overrideSeconds: 1,
        onTimeout: () async => timedOut = true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(timedOut, isTrue);

      sm.dispose();
    });
  });

  group('DialogueBargeInController Tests', () {
    test('1. 防回声剥离与忽略', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final tts = MockTtsPort();
      final matcher = MockTriggerMatcherPort();

      final controller = DialogueBargeInController(
        settings: buildSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
      );

      tts.recentlySpokenTextValue = '今天天气晴朗适合出门散步';
      final isEcho = controller.looksLikeAssistantEcho('适合出门散步');
      expect(isEcho, isTrue);

      final result = await controller.handlePlayingText('适合出门散步');
      expect(result.action, equals(BargeInActionType.ignoredEcho));
    });

    test('2. 纯停止词打断与声学缓冲冷却协同', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final tts = MockTtsPort()..isSpeakingValue = true;
      final matcher = MockTriggerMatcherPort();

      bool stopCalled = false;
      final controller = DialogueBargeInController(
        settings: buildSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
        onStopPlaying: (hint) async => stopCalled = true,
      );

      final result = await controller.handlePlayingBargeIn('停止');
      expect(result.action, equals(BargeInActionType.stopped));
      expect(stopCalled, isTrue);
      expect(audio.flushBuffersCount, equals(1));
      expect(audio.lastCooldownMs, equals(400));
    });

    test('3. 唤醒词新指令打断转入倾听', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final tts = MockTtsPort();
      final matcher = MockTriggerMatcherPort();

      String? acceptedRemaining;
      bool? acceptedStartMatched;

      final controller = DialogueBargeInController(
        settings: buildSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
        onBargeInAccepted: (rem, matched) async {
          acceptedRemaining = rem;
          acceptedStartMatched = matched;
        },
      );

      final result = await controller.handlePlayingBargeIn('小曼 讲个笑话');
      expect(result.action, equals(BargeInActionType.interrupted));
      expect(acceptedRemaining, contains('讲个笑话'));
      expect(acceptedStartMatched, isTrue);
    });

    test('4. 声纹鉴权拦截打断', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort()..allowVerification = false;
      final tts = MockTtsPort();
      final matcher = MockTriggerMatcherPort();

      String? rejectedReason;
      final controller = DialogueBargeInController(
        settings: buildSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
        onBargeInRejected: (r) => rejectedReason = r,
      );

      final result = await controller.handlePlayingBargeIn('停止');
      expect(result.action, equals(BargeInActionType.rejectedSpeaker));
      expect(rejectedReason, contains('声纹不匹配'));
    });
  });

  group('StreamingSentenceSegmenter Tests', () {
    test('1. 字符短碎片累积与门限拦截', () {
      final tts = MockTtsPort();
      final segmenter = StreamingSentenceSegmenter(
        ttsService: tts,
        minSentenceLength: 4,
      );

      // 输入 < 4 字符碎片
      final s1 = segmenter.feedChunk('好。');
      expect(s1, isEmpty);
      expect(segmenter.bufferedText, equals('好。'));
      expect(tts.enqueuedSentences, isEmpty);

      // 补充后续文本达到门限并分句
      final s2 = segmenter.feedChunk('今天天气很好！');
      expect(s2, isNotEmpty);
      expect(s2.first, equals('好。今天天气很好！'));
      expect(segmenter.bufferedText, isEmpty);
      expect(tts.enqueuedSentences, contains('好。今天天气很好！'));
    });

    test('2. 冲刷未闭合尾句', () async {
      final tts = MockTtsPort();
      final segmenter = StreamingSentenceSegmenter(ttsService: tts);

      segmenter.feedChunk('没有标点的尾部内容');
      expect(segmenter.bufferedText, equals('没有标点的尾部内容'));

      final flushed = await segmenter.flush();
      expect(flushed, equals('没有标点的尾部内容'));
      expect(segmenter.bufferedText, isEmpty);
      expect(tts.enqueuedSentences, contains('没有标点的尾部内容'));
    });
  });

  group('TranscriptTriggerCoordinator Tests', () {
    test('1. 两阶段 ASR 仲裁合并', () {
      final merged = TranscriptTriggerCoordinator.mergeStreamingTranscript(
        '今天的天气',
        '今天的天气怎么样',
      );
      expect(merged, equals('今天的天气怎么样'));

      final chosen = TranscriptTriggerCoordinator.chooseFinalTranscript(
        '帮我查今天天气',
        '帮我查询今天的天气情况',
      );
      expect(chosen, contains('今天'));
    });

    test('2. 停止词与退下词精准判别', () {
      final ttc = TranscriptTriggerCoordinator(
        settings: buildSettings(),
        emit: (_) {},
        onNotify: () {},
        audioControlPort: MockAudioControlPort(),
        speakerVerificationPort: MockSpeakerVerificationPort(),
        triggerMatcher: MockTriggerMatcherPort(),
        ttsService: MockTtsPort(),
        stateMachine: DialogueStateMachine(settings: buildSettings()),
        bargeInController: DialogueBargeInController(
          settings: buildSettings(),
          audioControlPort: MockAudioControlPort(),
          speakerVerificationPort: MockSpeakerVerificationPort(),
          ttsService: MockTtsPort(),
          triggerMatcher: MockTriggerMatcherPort(),
        ),
        onSubmitLlm: (_, {required isExplicitCommand}) async {},
      );

      expect(ttc.isPureStopWord('闭嘴'), isTrue);
      expect(ttc.isPureStopWord('别说了'), isTrue);
      expect(ttc.isPureStopWord('请你闭嘴好吗'), isFalse);
      expect(ttc.containsStopWord('请你闭嘴好吗'), isTrue);

      expect(ttc.isPureDismissWord('退下'), isTrue);
      expect(ttc.isPureDismissWord('退下吧'), isTrue);
      expect(ttc.containsDismissWord('小曼退下吧'), isTrue);
    });

    test('3. 任务串行排队队列保证 FIFO 顺序', () async {
      final ttc = TranscriptTriggerCoordinator(
        settings: buildSettings(),
        emit: (_) {},
        onNotify: () {},
        audioControlPort: MockAudioControlPort(),
        speakerVerificationPort: MockSpeakerVerificationPort(),
        triggerMatcher: MockTriggerMatcherPort(),
        ttsService: MockTtsPort(),
        stateMachine: DialogueStateMachine(settings: buildSettings()),
        bargeInController: DialogueBargeInController(
          settings: buildSettings(),
          audioControlPort: MockAudioControlPort(),
          speakerVerificationPort: MockSpeakerVerificationPort(),
          ttsService: MockTtsPort(),
          triggerMatcher: MockTriggerMatcherPort(),
        ),
        onSubmitLlm: (_, {required isExplicitCommand}) async {},
      );

      final sequence = <int>[];
      unawaited(ttc.enqueueTextProcess(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        sequence.add(1);
      }));
      unawaited(ttc.enqueueTextProcess(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        sequence.add(2);
      }));
      await ttc.enqueueTextProcess(() async {
        sequence.add(3);
      });

      expect(sequence, equals([1, 2, 3]));
    });
  });

  group('DialogueLlmOrchestrator Tests', () {
    test('1. 代系代次戳自增与防竞争', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final llm = MockLlmPort();
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildSettings());

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: llm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
      );

      expect(orchestrator.activeGenerationId, equals(0));
      final gen1 = orchestrator.nextGenerationId();
      expect(gen1, equals(1));
      expect(orchestrator.activeGenerationId, equals(1));

      orchestrator.cancelActiveGeneration();
      expect(orchestrator.activeGenerationId, equals(2));
    });

    test('2. 提交文本到大模型并完成分句朗读与会话更新', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final llm = MockLlmPort();
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildSettings());

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: llm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
      );

      await orchestrator.submitToLlm('介绍一下北京');

      expect(llm.callCount, equals(1));
      expect(session.messages.length, greaterThanOrEqualTo(2));
      expect(session.messages.first.content, equals('介绍一下北京'));
      expect(session.messages.last.content, contains('测试回复'));
    });

    test('3. 相机拍照联动与快门声', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final llm = MockLlmPort()
        ..replyStreamJson = '{"intent":"chat","reply":"已为您拍摄。"}';
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildSettings());

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: llm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
        onCapturePhotoDirect: () async {
          return CameraCaptureResult(
            filePath: 'mock/path.jpg',
            imageBytes: Uint8List.fromList([1, 2, 3]),
          );
        },
      );

      await orchestrator.sendTextMessage('拍张照片');
      expect(llm.callCount, equals(1));
    });
  });
}
