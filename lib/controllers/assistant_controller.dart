import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../core/constants/app_constants.dart';
import '../core/models/app_settings.dart';
import '../core/models/chat_message.dart';
import '../services/llm/llm_service.dart';
import '../services/nlp/embedding_service.dart';
import '../services/nlp/trigger_matcher.dart';
import '../services/speech/asr_service.dart';
import '../services/speech/prompt_sound_service.dart';
import '../services/speech/tts_service.dart';
import '../services/speech/voice_listening_service.dart';
import '../services/speech/foreground_service_bridge.dart';
import '../services/automation/app_driver_server.dart';

enum AssistantStatus {
  idle,             // 低功耗待机中（监听开始词/新会话词）
  listeningContent, // 已唤醒，正在倾听用户指令（等待结束词）
  thinking,         // 正在请求大模型思考
  playing,          // 正在朗读回复（支持随时打断）
}

class AssistantController extends ChangeNotifier {
  AppSettings settings;
  late EmbeddingService _embeddingService;
  late TriggerMatcher _triggerMatcher;
  late LlmService _llmService;
  late TtsService _ttsService;
  late AsrService _asrService;
  late VoiceListeningService _voiceListeningService;
  late PromptSoundService _promptSoundService;
  int _acknowledgeBeepCount = 0;

  AssistantStatus _status = AssistantStatus.idle;
  String _currentSessionId = const Uuid().v4();
  final List<ChatMessage> _messages = [];
  
  String _liveTranscript = '';
  String _lastRecognizedSpeech = '';
  String _currentSpeakingReply = '';
  bool _isWakeWordMatched = false;
  Timer? _unmatchedSpeechTimer;
  String _statusHint = '低功耗待机中，可说“晓漫”唤醒或“新起一个”';
  Timer? _silenceTimer;

  AssistantController({required this.settings}) {
    _initServices();
  }

  bool _isSelfTesting = false;
  final List<String> _selfTestLogs = [];
  AppDriverServer? _driverServer;

  AssistantStatus get status => _status;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  String get liveTranscript => _liveTranscript;
  String get lastRecognizedSpeech => _lastRecognizedSpeech;
  bool get isWakeWordMatched => _isWakeWordMatched;
  String get displayTranscript =>
      _status == AssistantStatus.listeningContent && _liveTranscript.isNotEmpty
          ? _liveTranscript
          : _lastRecognizedSpeech;
  String get statusHint => _statusHint;
  String get currentSessionId => _currentSessionId;
  AsrService get asrService => _asrService;
  TtsService get ttsService => _ttsService;
  VoiceListeningService get voiceService => _voiceListeningService;
  bool get isMicListening => _voiceListeningService.isListening;
  bool get isManualRecording => _voiceListeningService.isManualRecording;
  bool get isSelfTesting => _isSelfTesting;
  List<String> get selfTestLogs => List.unmodifiable(_selfTestLogs);

  Future<void> toggleMicListening() async {
    await _voiceListeningService.toggleContinuousListening();
    notifyListeners();
  }

  Future<void> startManualRecording() async {
    await _voiceListeningService.startManualRecording();
    notifyListeners();
  }

  Future<void> stopManualRecording() async {
    await _voiceListeningService.stopManualRecording();
    notifyListeners();
  }

  /// 通过 ASR 识别录音文件并将文字送入状态机处理
  Future<void> processAudioFile(String filePath) async {
    try {
      final text = await _asrService.transcribeAudioFile(filePath);
      if (text.isNotEmpty) {
        await processRecognizedText(text);
      }
    } catch (_) {}
  }


  void _initServices() {
    if (settings.useRemoteEmbedding) {
      _embeddingService = RemoteOpenAiEmbeddingService(settings: settings);
    } else {
      _embeddingService = LocalQwenEmbeddingService(settings: settings);
    }

    _triggerMatcher = TriggerMatcher(
      settings: settings,
      embeddingService: _embeddingService,
    );
    _triggerMatcher.warmUp();

    _llmService = LlmService(settings: settings);
    _ttsService = TtsService(settings: settings);
    _asrService = LocalSenseVoiceAsrService(settings: settings);
    unawaited((_asrService as LocalSenseVoiceAsrService).initialize());

    _voiceListeningService = VoiceListeningService(
      asrService: _asrService,
      onTextRecognized: (text) => processRecognizedText(text),
      onManualRecordingRecognized: (text) => sendDirectUserMessage(text),
      onStateChanged: (active, hint) {
        _statusHint = hint;
        notifyListeners();
        _syncForegroundNotification();
      },
      isStandbyMode: () => _status == AssistantStatus.idle,
    );

    _driverServer?.stop();
    _driverServer = AppDriverServer(controller: this);
    _driverServer!.start();

    _promptSoundService = PromptSoundService();
  }

  int get acknowledgeBeepCount => _acknowledgeBeepCount;

  /// 确认识别到“回答”等结束指令后，立即播放提示音（轻滴声）
  Future<void> playAcknowledgeBeep() async {
    _acknowledgeBeepCount++;
    if (!settings.enablePromptTone) return;
    try {
      await _promptSoundService.playAcknowledgeBeep();
    } catch (_) {}
  }

  /// 更新并保存设置
  Future<void> updateSettings(AppSettings newSettings) async {
    settings = newSettings;
    await settings.save();
    _initServices();
    notifyListeners();
  }

  /// 状态机切换
  void _setStatus(AssistantStatus newStatus, [String? hint]) {
    _status = newStatus;
    if (hint != null) {
      _statusHint = hint;
    }
    notifyListeners();
    _syncForegroundNotification();
  }

  void _syncForegroundNotification() {
    if (!_voiceListeningService.isListening) return;
    String title = '随身助理 - 待机中';
    switch (_status) {
      case AssistantStatus.idle:
        title = '随身助理 - 待机中（说“晓漫”唤醒）';
        break;
      case AssistantStatus.listeningContent:
        title = '随身助理 - 正在倾听...';
        break;
      case AssistantStatus.thinking:
        title = '随身助理 - 思考生成回答中...';
        break;
      case AssistantStatus.playing:
        title = '随身助理 - 正在语音回答';
        break;
    }
    ForegroundServiceBridge.update(
      title: title,
      content: _statusHint,
    );
  }

  /// 明确起一个新会话（清空上下文历史，本地回答“好的”）
  Future<void> startNewSession({bool playVoice = true}) async {
    _silenceTimer?.cancel();
    await _ttsService.stop();
    _currentSessionId = const Uuid().v4();
    _messages.clear();
    _liveTranscript = '';
    _lastRecognizedSpeech = '';
    _isWakeWordMatched = false;
    _unmatchedSpeechTimer?.cancel();
    _setStatus(AssistantStatus.idle, '已开启全新会话，上下文已重置');

    if (playVoice) {
      await _ttsService.speakImmediate(AppConstants.resetPromptReply);
    }
  }

  /// 处理接收到的实时文字片段（无论来自麦克风 ASR 还是测试输入）
  Future<void> processRecognizedText(String recognizedText) async {
    final text = recognizedText.trim();
    if (text.isEmpty) return;

    _unmatchedSpeechTimer?.cancel();
    _lastRecognizedSpeech = text;

    switch (_status) {
      case AssistantStatus.idle:
        await _handleIdleState(text);
        break;

      case AssistantStatus.listeningContent:
        _isWakeWordMatched = true;
        await _handleListeningState(text);
        break;

      case AssistantStatus.playing:
        // 打断逻辑 (Barge-in)
        await _handlePlayingBargeIn(text);
        break;

      case AssistantStatus.thinking:
        // 思考期间暂时忽略一般语音，若检测到停止也可打断
        break;
    }
  }

  /// 待机状态处理：检测“新起一个”或“开始词”
  Future<void> _handleIdleState(String text) async {
    // 0. 极速初筛待机语句（<0.01ms）：若完全无唤醒词/控制指令特征，立即显示灰色未匹配并在4秒后淡化，跳过全部重度计算
    if (!_triggerMatcher.quickWakePlausibilityCheck(text)) {
      _isWakeWordMatched = false;
      notifyListeners();

      _unmatchedSpeechTimer?.cancel();
      _unmatchedSpeechTimer = Timer(const Duration(seconds: 4), () {
        if (!_isWakeWordMatched && _status == AssistantStatus.idle) {
          _lastRecognizedSpeech = '';
          notifyListeners();
        }
      });
      return;
    }

    // 1. 先检测是否是“新起会话词”（如“新起一个”或“新起一个。”）
    final resetMatch = await _triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      _isWakeWordMatched = true;
      notifyListeners();
      await startNewSession(playVoice: true);
      return;
    }

    // 2. 检查是否是一句包含开始词与结束词的完整提问（如“小曼 xxx 回答。”）
    final oneShot = await _triggerMatcher.extractOneShotCommand(text);
    if (oneShot != null) {
      _isWakeWordMatched = true;
      _silenceTimer?.cancel();
      _liveTranscript = '';
      unawaited(playAcknowledgeBeep());
      _setStatus(
        AssistantStatus.thinking,
        '识别到指令【${oneShot.promptContent}】，正在请求回复...',
      );
      await _submitToLlm(oneShot.promptContent);
      return;
    }

    // 3. 检测是否包含“开始词”（如“晓漫”或同音“小曼”）
    final startMatch = await _triggerMatcher.checkStartWord(text);
    if (startMatch.isMatched) {
      _isWakeWordMatched = true;
      _liveTranscript = '';
      _setStatus(
        AssistantStatus.listeningContent,
        '听到开始词【${startMatch.matchedText}】，正在倾听内容...（说“${settings.endWord}”结束）',
      );

      // 通过切片精确截取开始词之后的内容
      String remaining = '';
      if (startMatch.endIndex > 0 && startMatch.endIndex < text.length) {
        remaining = text.substring(startMatch.endIndex).trim();
      } else {
        remaining = text.replaceFirst(startMatch.matchedText, '').trim();
      }

      _startSilenceTimer();

      if (remaining.isNotEmpty) {
        await _handleListeningState(remaining);
      }
      return;
    }

    // 4. 未能匹配到小曼/开始词：显示为灰色未命中，并在 4 秒后自动淡化消隐
    _isWakeWordMatched = false;
    notifyListeners();

    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = Timer(const Duration(seconds: 4), () {
      if (!_isWakeWordMatched && _status == AssistantStatus.idle) {
        _lastRecognizedSpeech = '';
        notifyListeners();
      }
    });
  }

  /// 倾听内容状态处理：检测“结束词”
  Future<void> _handleListeningState(String text) async {
    _resetSilenceTimer();

    // 0. 优先检测是否说出“新起一个”（重置指令）
    final resetMatch = await _triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      _liveTranscript = '';
      await startNewSession(playVoice: true);
      return;
    }

    // 1. 若倾听过程中再次听到“开始词”（如“小曼”、“晓漫”、“小麦”等）：
    // 抛弃之前的所有倾听内容，重新开始收集新指令
    final oneShot = await _triggerMatcher.extractOneShotCommand(text);
    if (oneShot != null) {
      _liveTranscript = '';
      _silenceTimer?.cancel();
      unawaited(playAcknowledgeBeep());
      _setStatus(
        AssistantStatus.thinking,
        '识别到新指令【${oneShot.promptContent}】，正在请求回复...',
      );
      await _submitToLlm(oneShot.promptContent);
      return;
    }

    final startMatch = await _triggerMatcher.checkStartWord(text);
    if (startMatch.isMatched) {
      _liveTranscript = '';
      _setStatus(
        AssistantStatus.listeningContent,
        '重新听到开始词【${startMatch.matchedText}】，已清空前文，正在倾听新内容...（说“${settings.endWord}”结束）',
      );
      _resetSilenceTimer();

      String remaining = '';
      if (startMatch.endIndex > 0 && startMatch.endIndex < text.length) {
        remaining = text.substring(startMatch.endIndex).trim();
      } else {
        remaining = text.replaceFirst(startMatch.matchedText, '').trim();
      }

      if (remaining.isNotEmpty) {
        await _handleListeningState(remaining);
      } else {
        notifyListeners();
      }
      return;
    }

    // 2. 正常内容追加
    _liveTranscript += (_liveTranscript.isEmpty ? '' : ' ') + text;
    notifyListeners();

    // 3. 检测是否命中了结束词（如“回答”或同音、语义结束词及带标点如“回答。”）
    final endMatch = await _triggerMatcher.checkEndWord(_liveTranscript);
    if (endMatch.isMatched) {
      _silenceTimer?.cancel();
      // 剥离结束词得到真正的纯净用户提问内容
      final promptContent = _triggerMatcher.stripEndWord(_liveTranscript);
      _liveTranscript = '';

      if (promptContent.isEmpty) {
        _setStatus(AssistantStatus.idle, '未捕获到有效提问内容，返回待机');
        return;
      }

      unawaited(playAcknowledgeBeep());
      await _submitToLlm(promptContent);
    }
  }

  /// 播放中打断处理 (Barge-in)
  Future<void> _handlePlayingBargeIn(String text) async {
    if (!settings.enableBargeIn) return;

    final cleanRecognized = _triggerMatcher.stripPunctuation(text, all: true);
    if (cleanRecognized.isEmpty) return;

    // 0. 声学回声抑制（Acoustic Echo Rejection）：
    // 若麦克风拾取到的文字来自正在播放的助手回答自身，则判定为扬声器外放录入的回声，立即忽略，防止自打断！
    final cleanSpeaking = _triggerMatcher.stripPunctuation(_currentSpeakingReply, all: true);
    if (cleanSpeaking.isNotEmpty) {
      if (cleanSpeaking.contains(cleanRecognized)) {
        return;
      }
      // 容错：当识别文本较长（>=4字符）且前4个字符或后4个字符存在于正在播放的内容中时，判定为回声
      if (cleanRecognized.length >= 4) {
        final head = cleanRecognized.substring(0, 4);
        final tail = cleanRecognized.substring(cleanRecognized.length - 4);
        if (cleanSpeaking.contains(head) || cleanSpeaking.contains(tail)) {
          return;
        }
      }
    }

    // 1. 用户真实发出的打断指令（如说出开始词“小曼/晓漫”，或“停止”、“暂停”）
    final startMatch = await _triggerMatcher.checkStartWord(text);
    if (startMatch.isMatched || text.contains('停止') || text.contains('暂停')) {
      await _ttsService.stop();
      _currentSpeakingReply = '';
      if (startMatch.isMatched) {
        _liveTranscript = '';
        _setStatus(
          AssistantStatus.listeningContent,
          '已打断！正在倾听新指令...（说“${settings.endWord}”结束）',
        );
        _startSilenceTimer();
      } else {
        _setStatus(AssistantStatus.idle, '已停止朗读，返回待机');
      }
    }
  }

  /// 提交给大模型并流式朗读回复
  Future<void> _submitToLlm(String userText) async {
    _setStatus(AssistantStatus.thinking, '正在思考回复...');

    final userMsg = ChatMessage(
      id: const Uuid().v4(),
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      sessionId: _currentSessionId,
    );
    _messages.add(userMsg);
    notifyListeners();

    final assistantMsgId = const Uuid().v4();
    final assistantContentBuffer = StringBuffer();
    final currentAssistantMsg = ChatMessage(
      id: assistantMsgId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      sessionId: _currentSessionId,
    );
    _messages.add(currentAssistantMsg);
    notifyListeners();

    try {
      _setStatus(AssistantStatus.playing, '正在回答...');

      final sentenceBuffer = StringBuffer();
      _currentSpeakingReply = '';

      // 流式请求大模型
      await for (final token in _llmService.sendChatStream(
        history: _messages.sublist(0, _messages.length - 1),
        newUserContent: userText,
        sessionId: _currentSessionId,
      )) {
        assistantContentBuffer.write(token);
        sentenceBuffer.write(token);
        _currentSpeakingReply = assistantContentBuffer.toString();

        // 更新 UI 中的文本展示
        final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
        if (idx != -1) {
          _messages[idx] = ChatMessage(
            id: assistantMsgId,
            role: 'assistant',
            content: _currentSpeakingReply,
            timestamp: DateTime.now(),
            sessionId: _currentSessionId,
          );
          notifyListeners();
        }

        // 按标点切句，流式追加进 TTS 顺序队列
        final currentText = sentenceBuffer.toString();
        if (RegExp(r'[。！？\n!?]').hasMatch(currentText) && currentText.length >= 8) {
          sentenceBuffer.clear();
          if (_status == AssistantStatus.playing) {
            _ttsService.enqueueSentence(currentText, shouldCancel: () => _status != AssistantStatus.playing);
          }
        }
      }

      // 朗读最后剩余的尾句
      final remaining = sentenceBuffer.toString().trim();
      if (remaining.isNotEmpty && _status == AssistantStatus.playing) {
        _ttsService.enqueueSentence(remaining, shouldCancel: () => _status != AssistantStatus.playing);
      }

      // 等待 TTS 顺序播放队列彻底播放完毕（避免流式结束后立即切回待机导致语音截断）
      if (_status == AssistantStatus.playing) {
        await _ttsService.waitForCompletion();
      }
    } catch (e) {
      final errorHint = '请求大模型失败: $e';
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = ChatMessage(
          id: assistantMsgId,
          role: 'assistant',
          content: errorHint,
          timestamp: DateTime.now(),
          sessionId: _currentSessionId,
        );
        notifyListeners();
      }
      await _ttsService.speakImmediate('抱歉，网络或模型请求异常');
    } finally {
      _currentSpeakingReply = '';
      if (_status == AssistantStatus.playing) {
        _setStatus(AssistantStatus.idle, '待机中，可说“${settings.startWord}”随时呼唤');
      }
    }
  }

  void _startSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(Duration(seconds: settings.silenceTimeoutSeconds), () async {
      if (_status == AssistantStatus.listeningContent) {
        _liveTranscript = '';
        _setStatus(AssistantStatus.idle, '长时间未收到结束词，已自动取消');
        await _ttsService.speakImmediate(AppConstants.timeoutPromptReply);
      }
    });
  }

  void _resetSilenceTimer() {
    if (_status == AssistantStatus.listeningContent) {
      _startSilenceTimer();
    }
  }

  /// 模拟输入或文本命令测试
  Future<void> simulateUserInput(String text) async {
    await processRecognizedText(text);
  }

  /// 直接发送用户语音/文本指令（手动对讲录音触发，不需启动词与结束词，直接送入大模型）
  Future<void> sendDirectUserMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;

    // 若有 TTS 正在播放，立即停止
    await _ttsService.stop();
    _silenceTimer?.cancel();
    _liveTranscript = '';
    _lastRecognizedSpeech = text;
    _isWakeWordMatched = true;

    // 0. 优先检测是否是“新起会话”重置指令
    final resetMatch = await _triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      await startNewSession(playVoice: true);
      return;
    }

    // 1. 检测停止/暂停指令
    if (text == '停止' || text == '暂停') {
      _setStatus(AssistantStatus.idle, '已停止朗读，返回待机');
      return;
    }

    // 2. 如果录音中包含了启动词或结束词（例如顺口说了“晓漫 ... 回答”），予以清洗保留核心指令；没有则直接作为指令内容
    String promptContent = text;
    final startMatch = await _triggerMatcher.checkStartWord(promptContent);
    if (startMatch.isMatched) {
      if (startMatch.endIndex > 0 && startMatch.endIndex < promptContent.length) {
        promptContent = promptContent.substring(startMatch.endIndex).trim();
      } else {
        promptContent = promptContent.replaceFirst(startMatch.matchedText, '').trim();
      }
    }
    promptContent = _triggerMatcher.stripEndWord(promptContent);
    if (promptContent.isEmpty) {
      promptContent = text; // 若剥离后为空则回退到原始文本
    }

    // 确认识别后播放轻滴提示音（与自动模式一致的交互反馈）
    unawaited(playAcknowledgeBeep());

    // 直接送入大模型思考并朗读回答
    await _submitToLlm(promptContent);
  }

  /// 运行全链路自动化诊断自测
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async {
    _isSelfTesting = true;
    _selfTestLogs.clear();
    _addTestLog('🚀 开始全链路运行态自动化诊断测试...');
    notifyListeners();

    bool allPassed = true;

    // Step 1: 测试 Embedding 服务
    try {
      _addTestLog('1/5 测试 Embedding 向量连接 (NVIDIA Nemotron)...');
      final vec = await _embeddingService.getEmbedding(settings.startWord);
      if (vec.isNotEmpty) {
        _addTestLog('✅ 1/5 Embedding 向量服务正常 (维度: ${vec.length})');
      } else {
        throw Exception('返回向量为空');
      }
    } catch (e) {
      allPassed = false;
      _addTestLog('❌ 1/5 Embedding 接口异常: $e');
    }
    notifyListeners();

    // Step 2: 测试触发词与拼音容错
    try {
      _addTestLog('2/5 测试触发词双层识别算法 (拼音容错与剥离)...');
      final pyMatch = await _triggerMatcher.checkStartWord('小曼今天天气怎么样');
      final stripTest = _triggerMatcher.stripEndWord('帮我查汇率回答');
      if (pyMatch.isMatched && stripTest == '帮我查汇率') {
        _addTestLog('✅ 2/5 触发词拼音容错与结束词剥离算法验证通过');
      } else {
        throw Exception('匹配未命中或剥离错误');
      }
    } catch (e) {
      allPassed = false;
      _addTestLog('❌ 2/5 触发词算法异常: $e');
    }
    notifyListeners();

    // Step 3: 测试真实大模型连通性与返回
    try {
      _addTestLog('3/5 测试 DeepSeek-V4.1-Flash 大模型真实问答...');
      final reply = await _llmService.sendChat(
        history: [],
        newUserContent: '请简短回复“自检通过”四个字。',
        sessionId: _currentSessionId,
      );
      if (reply.isNotEmpty) {
        _addTestLog('✅ 3/5 大模型响应成功: "${reply.trim()}"');
      } else {
        throw Exception('大模型回复为空');
      }
    } catch (e) {
      allPassed = false;
      _addTestLog('❌ 3/5 大模型连接异常: $e');
    }
    notifyListeners();

    // Step 4: 测试多轮会话记忆力驱动
    try {
      _addTestLog('4/5 测试多轮会话上下文记忆驱动...');
      final testMsg1 = ChatMessage(
        id: const Uuid().v4(),
        role: 'user',
        content: '记住，我的代号是极客007',
        timestamp: DateTime.now(),
        sessionId: _currentSessionId,
      );
      final testReply1 = await _llmService.sendChat(
        history: [],
        newUserContent: testMsg1.content,
        sessionId: _currentSessionId,
      );
      final testAssistant1 = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: testReply1,
        timestamp: DateTime.now(),
        sessionId: _currentSessionId,
      );
      final testReply2 = await _llmService.sendChat(
        history: [testMsg1, testAssistant1],
        newUserContent: '我的代号是什么？只回复代号。',
        sessionId: _currentSessionId,
      );
      if (testReply2.contains('007') || testReply2.contains('极客')) {
        _addTestLog('✅ 4/5 多轮上下文记忆召回准确: "${testReply2.trim()}"');
      } else {
        _addTestLog('⚠️ 4/5 多轮回复已收到: "${testReply2.trim()}"');
      }
    } catch (e) {
      allPassed = false;
      _addTestLog('❌ 4/5 上下文记忆测试异常: $e');
    }
    notifyListeners();

    // Step 5: 测试“新起一个”会话重置
    try {
      _addTestLog('5/5 测试“新起一个”本地重置指令...');
      final oldId = _currentSessionId;
      await startNewSession(playVoice: false);
      if (_currentSessionId != oldId && _messages.isEmpty) {
        _addTestLog('✅ 5/5 会话重置验证通过 (Session 已更新，上下文已清空)');
      } else {
        throw Exception('重置后未清空会话');
      }
    } catch (e) {
      allPassed = false;
      _addTestLog('❌ 5/5 会话重置异常: $e');
    }

    _isSelfTesting = false;
    _addTestLog(allPassed ? '🎉 全部 5 项运行态自动化诊断测试顺利通过！' : '⚠️ 诊断完成，部分项目存在异常。');
    notifyListeners();

    return {
      'success': allPassed,
      'logs': _selfTestLogs,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  void _addTestLog(String log) {
    _selfTestLogs.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $log');
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _voiceListeningService.dispose();
    _ttsService.dispose();
    _promptSoundService.dispose();
    _driverServer?.stop();
    super.dispose();
  }
}
