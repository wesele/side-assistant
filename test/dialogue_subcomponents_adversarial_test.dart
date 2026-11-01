import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_barge_in_controller.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_llm_orchestrator.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/dialogue_state_machine.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/streaming_sentence_segmenter.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/transcript_trigger_coordinator.dart';
import 'package:side_assistant/core/engine/engine_events.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/assistant_status.dart';
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
  String? rejectionReasonToProvide;

  @override
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) {
    verifyCount++;
    if (!allowVerification) {
      onRejected?.call(rejectionReasonToProvide ?? '声纹不匹配');
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
  int stopCallCount = 0;
  int waitForCompletionCallCount = 0;

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
  Future<void> waitForCompletion() async {
    waitForCompletionCallCount++;
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
    isSpeakingValue = false;
  }

  @override
  Future<void> previewVoice({required String voice, required String text}) async {}

  @override
  void applyConfig(dynamic config) {}

  @override
  void dispose() {}
}

class MockTriggerMatcherPort implements TriggerMatcherPort {
  String startWord = '小曼';
  String endWord = '回答';
  String resetWord = '新起一个';
  String exitContinuousWord = '退下吧';

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
    if (text.contains(resetWord)) {
      final idx = text.indexOf(resetWord);
      return TriggerMatchResult(
        type: TriggerType.reset,
        matchedText: resetWord,
        similarity: 1.0,
        method: 'exact',
        startIndex: idx,
        endIndex: idx + resetWord.length,
      );
    }
    return TriggerMatchResult.none();
  }

  @override
  Future<bool> checkExitContinuousWord(String text) async {
    return text.contains(exitContinuousWord) ||
        text.contains('退出') ||
        text.contains('结束对话') ||
        text.contains('退下');
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
  String currentSessionId = 'session_alpha';
  final List<ChatMessage> _messages = [];
  int syncCallCount = 0;

  @override
  List<ChatMessage> get messages => _messages;

  @override
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  }) {
    final uId = 'u_${_messages.length + 1}';
    final aId = 'a_${_messages.length + 2}';
    _messages.add(ChatMessage(
      id: uId,
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      imagePath: imagePath,
    ));
    _messages.add(ChatMessage(
      id: aId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
    ));
    return (
      userMsgId: uId,
      assistantMsgId: aId,
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
  }) async => sourcePath ?? 'persisted/$messageId.png';

  @override
  Future<ChatSession?> syncCurrentSession({bool persist = true}) async {
    syncCallCount++;
    return null;
  }

  @override
  Future<ChatSession?> startNewSession() async => null;

  @override
  Future<ChatSession?> switchSession(String sessionId) async => null;

  @override
  void updateLightRagService(dynamic service) {}
}

class MockControllableLlmPort implements LlmPort {
  int callCount = 0;
  final StreamController<String> _streamController = StreamController<String>();

  void emitToken(String token) {
    _streamController.add(token);
  }

  void closeStream() {
    _streamController.close();
  }

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
  }) {
    callCount++;
    return _streamController.stream;
  }

  @override
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  }) async => '';

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
  AppSettings buildDefaultSettings() => AppSettings(
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
        continuousModeTimeoutMinutes: 1,
        startWordMode: AppConstants.startWordModeEnabled,
      );

  group('Adversarial M2-1 Suite 1: DialogueStateMachine Deep Isolation Tests', () {
    test('1.1 完整状态生命周期跃迁与异常状态提示文案', () {
      final audio = MockAudioControlPort();
      final sm = DialogueStateMachine(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
      );

      expect(sm.status, equals(AssistantStatus.idle));
      expect(sm.statusShortLabel, equals('待机'));

      // 跃迁至倾听态
      sm.setStatus(AssistantStatus.listeningContent, '正在倾听用户说话');
      expect(sm.status, equals(AssistantStatus.listeningContent));
      expect(sm.statusShortLabel, equals('倾听'));
      expect(sm.statusHint, equals('正在倾听用户说话'));

      // 跃迁至思考态
      sm.setStatus(AssistantStatus.thinking, '正在思考中');
      expect(sm.status, equals(AssistantStatus.thinking));
      expect(sm.statusShortLabel, equals('思考'));

      // 跃迁至播报态
      sm.setStatus(AssistantStatus.playing, '正在播报回复');
      expect(sm.status, equals(AssistantStatus.playing));
      expect(sm.statusShortLabel, equals('播报'));

      // 跃迁回待机态（异常失败提示）
      sm.setStatus(AssistantStatus.idle, '网络请求异常失败');
      expect(sm.status, equals(AssistantStatus.idle));
      expect(sm.statusShortLabel, equals('失败'));

      // 麦克风关闭时的硬件兜底提示修正
      audio.isMicListening = false;
      sm.setStatus(AssistantStatus.idle, '可说“小曼”随时唤醒');
      expect(sm.statusHint, equals('话筒未开启，点击右上角开启语音监听'));

      sm.dispose();
      expect(sm.isDisposed, isTrue);
    });

    test('1.2 连续对话生命周期、超时退出与设置切换自动退出', () async {
      final settings = buildDefaultSettings()
        ..startWordMode = AppConstants.startWordModeAuto
        ..continuousModeTimeoutMinutes = 1;
      final audio = MockAudioControlPort();
      final tts = MockTtsPort();

      bool? continuousFlag;
      String? exitReason;

      final sm = DialogueStateMachine(
        settings: settings,
        audioControlPort: audio,
        ttsService: tts,
        onContinuousModeChanged: (val, reason) {
          continuousFlag = val;
          exitReason = reason;
        },
      );

      // 进入连续对话模式
      sm.enterContinuousMode();
      expect(sm.isInContinuousMode, isTrue);
      expect(continuousFlag, isTrue);
      expect(sm.statusShortLabel, equals('连续对话'));

      // 非 auto 模式下进入无效
      sm.updateSettings(buildDefaultSettings()..startWordMode = AppConstants.startWordModeEnabled);
      expect(sm.isInContinuousMode, isFalse);
      expect(continuousFlag, isFalse);

      // 重新恢复 auto 并进入
      sm.updateSettings(settings);
      sm.enterContinuousMode();
      expect(sm.isInContinuousMode, isTrue);

      // 用户主动退出
      await sm.exitContinuousMode(byUser: true);
      expect(sm.isInContinuousMode, isFalse);
      expect(audio.flushBuffersCount, greaterThanOrEqualTo(1));
      expect(audio.lastCooldownMs, equals(400));
      expect(tts.spokenSentences, contains(AppConstants.exitContinuousPromptReply));
      expect(exitReason, isNull);

      sm.dispose();
    });

    test('1.3 静音超时计时器连续重置防过早触发与状态改变防护', () async {
      int timeoutCount = 0;
      final sm = DialogueStateMachine(
        settings: buildDefaultSettings(),
        onSilenceTimeout: () async {
          timeoutCount++;
        },
      );

      sm.setStatus(AssistantStatus.listeningContent, '倾听中');
      sm.startSilenceTimer(overrideSeconds: 1);

      // 在 400ms 时重置
      await Future<void>.delayed(const Duration(milliseconds: 400));
      sm.resetSilenceTimer();

      // 在 800ms 时再次重置
      await Future<void>.delayed(const Duration(milliseconds: 400));
      sm.resetSilenceTimer();

      // 验证重置后尚未超时
      expect(timeoutCount, equals(0));

      // 在 1200ms（距上次重置 400ms）时状态变迁为 thinking
      await Future<void>.delayed(const Duration(milliseconds: 400));
      sm.setStatus(AssistantStatus.thinking, '正在处理');

      // 再等待 1200ms，确保原来的静音计时器不会因为已离开 listeningContent 而错误触发
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(timeoutCount, equals(0));

      sm.dispose();
    });
  });

  group('Adversarial M2-1 Suite 2: DialogueBargeInController Deep Isolation Tests', () {
    test('2.1 防外放回声智能辨识：全量包含、后缀命中、带唤醒词混合识别', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final tts = MockTtsPort();
      final matcher = MockTriggerMatcherPort();

      final controller = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
      );

      tts.recentlySpokenTextValue = '人工智能助手小曼正在为您查询北京今日的天气与路况信息。';

      // 1. 完全是外放片段 -> 回声判定
      expect(controller.looksLikeAssistantEcho('北京今日的天气与路况信息'), isTrue);
      final echoResult = await controller.handlePlayingText('北京今日的天气与路况信息');
      expect(echoResult.action, equals(BargeInActionType.ignoredEcho));

      // 2. 播报期间混音带打断词 -> 剥离回声后保留打断词
      // 混音文本："正在为您查询小曼停止" -> stripAssistantEcho 会剥离 "正在为您查询"，保留 "小曼停止" 或 "停止"
      final stripped = controller.stripAssistantEcho('正在为您查询北京小曼停止');
      expect(stripped, isNotEmpty);
      expect(stripped.contains('停止') || stripped.contains('小曼'), isTrue);

      // 3. 打断功能关闭时的行为
      controller.updateSettings(buildDefaultSettings()..enableBargeIn = false);
      final disabledResult = await controller.handlePlayingText('停止');
      expect(disabledResult.action, equals(BargeInActionType.ignoredDisabled));
    });

    test('2.2 纯停止词 vs 语句夹带停止词 vs 退出连续对话 vs 普通非打断语音', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final tts = MockTtsPort()..isSpeakingValue = true;
      final matcher = MockTriggerMatcherPort();

      bool exitContinuousInvoked = false;
      bool stopPlayingInvoked = false;

      final controller = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
        onExitContinuous: () async => exitContinuousInvoked = true,
        onStopPlaying: (_) async => stopPlayingInvoked = true,
      );

      // 1. 连续模式下的纯退下词 -> exitContinuous
      final rExit = await controller.handlePlayingBargeIn('退下', isInContinuousMode: true);
      expect(rExit.action, equals(BargeInActionType.stopped));
      expect(rExit.exitedContinuous, isTrue);
      expect(exitContinuousInvoked, isTrue);
      expect(audio.flushBuffersCount, equals(1));
      expect(audio.lastCooldownMs, equals(400));
      expect(tts.stopCallCount, equals(1));

      // 2. 纯停止词 -> stopped
      final rStop = await controller.handlePlayingBargeIn('别说了', isInContinuousMode: false);
      expect(rStop.action, equals(BargeInActionType.stopped));
      expect(rStop.exitedContinuous, isFalse);
      expect(stopPlayingInvoked, isTrue);

      // 3. 普通非打断日常语音 -> ignoredNotTrigger
      final rNormal = await controller.handlePlayingBargeIn('明天去哪里吃饭呢', isInContinuousMode: false);
      expect(rNormal.action, equals(BargeInActionType.ignoredNotTrigger));

      // 4. 空文本 -> ignoredDisabled
      final rEmpty = await controller.handlePlayingBargeIn('   ', isInContinuousMode: false);
      expect(rEmpty.action, equals(BargeInActionType.ignoredDisabled));
    });

    test('2.3 声纹鉴权拒绝打断防护', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort()
        ..allowVerification = false
        ..rejectionReasonToProvide = '非机主声音，已拦截打断';
      final tts = MockTtsPort()..isSpeakingValue = true;
      final matcher = MockTriggerMatcherPort();

      String? capturedReject;
      final controller = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
        onBargeInRejected: (r) => capturedReject = r,
      );

      final result = await controller.handlePlayingBargeIn('停止');
      expect(result.action, equals(BargeInActionType.rejectedSpeaker));
      expect(result.rejectionReason, contains('非机主声音'));
      expect(capturedReject, contains('非机主声音'));
      // 鉴权未通过时严禁终止 TTS
      expect(tts.stopCallCount, equals(0));
    });
  });

  group('Adversarial M2-1 Suite 3: StreamingSentenceSegmenter Deep Isolation Tests', () {
    test('3.1 各种中英文标点 ([。！？\\n!?]) 分句切片与连续标点处理', () {
      final tts = MockTtsPort();
      final receivedSentences = <String>[];
      final segmenter = StreamingSentenceSegmenter(
        ttsService: tts,
        minSentenceLength: 4,
        onSentenceEnqueued: receivedSentences.add,
      );

      // 中文句号
      final s1 = segmenter.feedChunk('这是第一句话。');
      expect(s1, equals(['这是第一句话。']));

      // 中文感叹号
      final s2 = segmenter.feedChunk('太精彩了！');
      expect(s2, equals(['太精彩了！']));

      // 中文问号
      final s3 = segmenter.feedChunk('请问需要帮忙吗？');
      expect(s3, equals(['请问需要帮忙吗？']));

      // 换行符
      final s4 = segmenter.feedChunk('这里换了一行\n');
      expect(s4, equals(['这里换了一行\n']));

      // 英文感叹号与问号
      final s5 = segmenter.feedChunk('Wonderful! How about this?');
      expect(s5, isNotEmpty);
      expect(segmenter.bufferedText, isEmpty);

      expect(tts.enqueuedSentences.length, equals(5));
      expect(receivedSentences.length, equals(5));
    });

    test('3.2 字符长度门限（默认 4 字符）与残余累积切分', () {
      final tts = MockTtsPort();
      final segmenter = StreamingSentenceSegmenter(
        ttsService: tts,
        minSentenceLength: 4,
      );

      // '嗯。' (2字符 < 4) 不应当即时切句
      final chunk1 = segmenter.feedChunk('嗯。');
      expect(chunk1, isEmpty);
      expect(segmenter.bufferedText, equals('嗯。'));
      expect(tts.enqueuedSentences, isEmpty);

      // '收到。' (3字符 < 4)，加上原缓冲区为 '嗯。收到。' (5字符 >= 4)，应当切出
      final chunk2 = segmenter.feedChunk('收到。');
      expect(chunk2, equals(['嗯。收到。']));
      expect(segmenter.bufferedText, isEmpty);
      expect(tts.enqueuedSentences, equals(['嗯。收到。']));
    });

    test('3.3 冲刷未闭合尾句、条件取消与等待完成 (flush & waitForCompletion)', () async {
      final tts = MockTtsPort();
      final segmenter = StreamingSentenceSegmenter(ttsService: tts);

      segmenter.feedChunk('这是一段未闭合的末尾文本');
      expect(segmenter.hasBufferedText, isTrue);

      // canEnqueue 为 false 时，冲刷返回文本但不送入 TTS
      final flushedText1 = await segmenter.flush(
        canEnqueue: () => false,
      );
      expect(flushedText1, equals('这是一段未闭合的末尾文本'));
      expect(tts.enqueuedSentences, isEmpty);
      expect(segmenter.hasBufferedText, isFalse);

      // 重新推入一段文本并正常冲刷等待完成
      segmenter.feedChunk('最终结论已完成');
      final flushedText2 = await segmenter.flush(
        waitForCompletion: true,
      );
      expect(flushedText2, equals('最终结论已完成'));
      expect(tts.enqueuedSentences, contains('最终结论已完成'));
      expect(tts.waitForCompletionCallCount, equals(1));
    });
  });

  group('Adversarial M2-1 Suite 4: TranscriptTriggerCoordinator Deep Isolation Tests', () {
    test('4.1 唤醒词、结束词、重置词、退下词完整仲裁流程', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final matcher = MockTriggerMatcherPort();
      final tts = MockTtsPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());
      final bargeIn = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
      );

      String? submittedPrompt;
      bool submittedExplicit = false;
      bool beepPlayed = false;
      bool newSessionStarted = false;

      final ttc = TranscriptTriggerCoordinator(
        settings: buildDefaultSettings(),
        emit: (_) {},
        onNotify: () {},
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        triggerMatcher: matcher,
        ttsService: tts,
        stateMachine: sm,
        bargeInController: bargeIn,
        onSubmitLlm: (prompt, {required isExplicitCommand}) async {
          submittedPrompt = prompt;
          submittedExplicit = isExplicitCommand;
        },
        onPlayAcknowledgeBeep: () async => beepPlayed = true,
        onStartNewSession: ({bool playVoice = true}) async => newSessionStarted = true,
      );

      // 1. 待机态收到一步达指令: "小曼查询明天的天气"
      await ttc.processRecognizedText('小曼查询明天的天气');
      expect(submittedPrompt, equals('查询明天的天气'));
      expect(submittedExplicit, isTrue);
      expect(beepPlayed, isTrue);
      expect(sm.status, equals(AssistantStatus.thinking));

      // 2. 状态重置为待机态，收到重置会话词: "新起一个"
      sm.setStatus(AssistantStatus.idle, '待机');
      await ttc.processRecognizedText('新起一个');
      expect(newSessionStarted, isTrue);

      // 3. 待机态收到单纯唤醒词: "小曼" -> 进入倾听态
      sm.setStatus(AssistantStatus.idle, '待机');
      await ttc.processRecognizedText('小曼');
      expect(sm.status, equals(AssistantStatus.listeningContent));
      expect(ttc.isWakeWordMatched, isTrue);

      // 4. 倾听态接收流式增量并在到达结束词时提交: "故宫门票多少钱回答"
      await ttc.processPartialTranscript('故宫门票多少钱');
      expect(ttc.liveTranscript, equals('故宫门票多少钱'));

      await ttc.processPartialTranscript('故宫门票多少钱回答');
      expect(submittedPrompt, equals('故宫门票多少钱'));
      expect(sm.status, equals(AssistantStatus.thinking));

      // 5. 只有结束词没有内容时的防御: "回答"
      sm.setStatus(AssistantStatus.listeningContent, '倾听中');
      ttc.liveTranscript = '回答';
      final endMatch = await matcher.checkEndWord('回答');
      await ttc.submitLiveTranscript(endMatch);
      expect(sm.status, equals(AssistantStatus.idle));
      expect(sm.statusHint, contains('只听到结束词'));

      ttc.dispose();
      sm.dispose();
    });

    test('4.2 两阶段 ASR 仲裁合并与非倾听态过滤', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final matcher = MockTriggerMatcherPort();
      final tts = MockTtsPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());
      final bargeIn = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
      );

      final events = <AssistantEngineEvent>[];
      final ttc = TranscriptTriggerCoordinator(
        settings: buildDefaultSettings(),
        emit: events.add,
        onNotify: () {},
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        triggerMatcher: matcher,
        ttsService: tts,
        stateMachine: sm,
        bargeInController: bargeIn,
        onSubmitLlm: (_, {required isExplicitCommand}) async {},
      );

      // 待机态时收到离线复检最终文本 -> 忽略不更新 liveTranscript
      sm.setStatus(AssistantStatus.idle);
      await ttc.processFinalTranscript('这是一段离线识别');
      expect(ttc.liveTranscript, isEmpty);

      // 切到倾听态
      sm.setStatus(AssistantStatus.listeningContent);
      await ttc.processPartialTranscript('北京天气');
      expect(ttc.liveTranscript, equals('北京天气'));

      // 离线精检到达，覆盖合并 (nb.contains(na))
      await ttc.processFinalTranscript('北京天气怎么样');
      expect(ttc.liveTranscript, equals('北京天气怎么样'));
      expect(events.whereType<TranscriptUpdatedEvent>().last.isFinal, isTrue);

      ttc.dispose();
      sm.dispose();
    });

    test('4.3 任务队列串行 FIFO 严密并发压力测试', () async {
      final audio = MockAudioControlPort();
      final speaker = MockSpeakerVerificationPort();
      final matcher = MockTriggerMatcherPort();
      final tts = MockTtsPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());
      final bargeIn = DialogueBargeInController(
        settings: buildDefaultSettings(),
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        ttsService: tts,
        triggerMatcher: matcher,
      );

      final ttc = TranscriptTriggerCoordinator(
        settings: buildDefaultSettings(),
        emit: (_) {},
        onNotify: () {},
        audioControlPort: audio,
        speakerVerificationPort: speaker,
        triggerMatcher: matcher,
        ttsService: tts,
        stateMachine: sm,
        bargeInController: bargeIn,
        onSubmitLlm: (_, {required isExplicitCommand}) async {},
      );

      final executedOrder = <int>[];
      final futures = <Future<void>>[];

      for (int i = 1; i <= 20; i++) {
        final id = i;
        futures.add(ttc.enqueueTextProcess(() async {
          // 模拟不同微小延迟
          await Future<void>.delayed(Duration(milliseconds: (20 - id) % 5 + 1));
          executedOrder.add(id);
        }));
      }

      await Future.wait(futures);
      expect(executedOrder, equals(List.generate(20, (i) => i + 1)));

      ttc.dispose();
      sm.dispose();
    });
  });

  group('Adversarial M2-1 Suite 5: DialogueLlmOrchestrator Deep Isolation Tests', () {
    test('5.1 activeGenerationId 代系自增与异步响应竞态淘汰', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final controllableLlm = MockControllableLlmPort();
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildDefaultSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: controllableLlm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
      );

      expect(orchestrator.activeGenerationId, equals(0));

      // 启动请求 1 (Generation 1)
      final future1 = orchestrator.submitToLlm('第一个问题');
      expect(orchestrator.activeGenerationId, equals(1));
      expect(controllableLlm.callCount, equals(1));

      // 在请求 1 处理过程中，代次被取消或被新请求 2 (Generation 2) 替换
      orchestrator.cancelActiveGeneration();
      expect(orchestrator.activeGenerationId, equals(2));

      // 此时请求 1 的 token 才姗姗来迟到达
      controllableLlm.emitToken('{"intent":"chat","reply":"这是过时请求1的回答。"}');
      controllableLlm.closeStream();

      await future1;

      // 验证请求 1 的过时 token 被完全丢弃，TTS 队列中没有入队该内容
      expect(tts.enqueuedSentences, isEmpty);

      sm.dispose();
    });

    test('5.2 会话 SessionId 切换时的流式响应防护', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final controllableLlm = MockControllableLlmPort();
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildDefaultSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: controllableLlm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
      );

      session.currentSessionId = 'session_AAA';
      final future = orchestrator.submitToLlm('介绍会话AAA');

      // 模拟用户在 LLM 流式回答中切换了当前会话至 session_BBB
      session.currentSessionId = 'session_BBB';

      controllableLlm.emitToken('{"intent":"chat","reply":"会话AAA的内容。"}');
      controllableLlm.closeStream();

      await future;

      // 验证会话切换后，旧会话的 TTS 播报被终止，未污染新会话
      expect(tts.enqueuedSentences, isEmpty);

      sm.dispose();
    });

    test('5.3 直接用户输入打断与控制词预检 (prepareDirectUserInput)', () async {
      final session = MockSessionMessagePort();
      final audio = MockAudioControlPort();
      final llm = MockControllableLlmPort();
      final tts = MockTtsPort();
      final prompt = MockPromptSoundPort();
      final matcher = MockTriggerMatcherPort();
      final sm = DialogueStateMachine(settings: buildDefaultSettings());

      bool newSessionTriggered = false;

      final orchestrator = DialogueLlmOrchestrator(
        settings: buildDefaultSettings(),
        emit: (_) {},
        onNotify: () {},
        sessionMessagePort: session,
        audioControlPort: audio,
        llmService: llm,
        ttsService: tts,
        promptSoundService: prompt,
        triggerMatcher: matcher,
        stateMachine: sm,
        onStartNewSession: ({bool playVoice = true}) async => newSessionTriggered = true,
      );

      // 1. 输入 "停止"
      sm.setStatus(AssistantStatus.playing);
      final handledStop = await orchestrator.prepareDirectUserInput('停止');
      expect(handledStop, isTrue);
      expect(sm.status, equals(AssistantStatus.idle));
      expect(sm.statusHint, contains('已停止朗读'));
      expect(audio.flushBuffersCount, greaterThanOrEqualTo(1));

      // 2. 输入 "新起一个"
      final handledReset = await orchestrator.prepareDirectUserInput('新起一个');
      expect(handledReset, isTrue);
      expect(newSessionTriggered, isTrue);

      // 3. 普通文本提问 -> prepareDirectUserInput 返回 false，进入正常提交流程
      final handledNormal = await orchestrator.prepareDirectUserInput('请讲个笑话');
      expect(handledNormal, isFalse);

      sm.dispose();
    });
  });
}
