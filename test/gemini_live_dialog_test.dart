import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/platform/pcm_stream_player_bridge.dart';
import 'package:side_assistant/core/ports/gemini_live_session_port.dart';
import 'package:side_assistant/core/ports/tts_port.dart';
import 'package:side_assistant/services/speech/gemini_live_dialog_service.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_protocol.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_setup.dart';
import 'package:side_assistant/services/speech/support/gemini_live_pcm.dart';

class _FakeGeminiLiveSession extends NullGeminiLiveSessionPort {
  bool _connected = false;
  bool fakeIsSpeakingOutput = false;
  int connectCalls = 0,
      disconnectCalls = 0,
      stopSpeakingCalls = 0,
      fedAudioChunks = 0,
      previewVoiceCalls = 0;
  final List<String> sentTexts = [];
  bool? lastResetSessionFlag;
  String? lastPreviewVoice, lastPreviewText;

  @override
  bool get isReady => _connected;
  @override
  bool get isActive => _connected;
  @override
  bool get isSpeakingOutput => fakeIsSpeakingOutput;
  @override
  Future<bool> connect() async {
    connectCalls++;
    _connected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
  }

  @override
  void feedAudioSamples(Float32List samples, {int sampleRate = 16000}) =>
      fedAudioChunks++;

  @override
  Future<void> sendClientText(
    String text, {
    Uint8List? imageBytes,
    String? imagePath,
  }) async =>
      sentTexts.add(text);

  @override
  Future<void> syncSessionContext(
    List<ChatMessage> history, {
    bool resetSession = false,
  }) async =>
      lastResetSessionFlag = resetSession;

  @override
  Future<void> previewVoice({
    required String voice,
    String? text,
    String? apiKey,
    String? model,
  }) async {
    previewVoiceCalls++;
    lastPreviewVoice = voice;
    lastPreviewText = text;
  }

  @override
  Future<void> stopSpeaking() async => stopSpeakingCalls++;
  @override
  void dispose() => _connected = false;
}

class _FakeTtsPort extends NoopTtsPort {
  int previewVoiceCalls = 0;
  String? lastVoice, lastText;
  final List<String> spokenTexts = <String>[];
  int stopCalls = 0;

  @override
  Future<void> previewVoice({
    required String voice,
    required String text,
  }) async {
    previewVoiceCalls++;
    lastVoice = voice;
    lastText = text;
  }

  @override
  Future<void> speakImmediate(String text) async {
    spokenTexts.add(text);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _FakeLiveWebSocket extends Stream<dynamic> implements WebSocket {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<dynamic> sentMessages = <dynamic>[];
  final bool autoSetupComplete;

  int? _closeCode;
  String? _closeReason;

  _FakeLiveWebSocket({this.autoSetupComplete = true});

  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;

  void emit(dynamic data) {
    if (!_controller.isClosed) _controller.add(data);
  }

  void closeFromServer([int? code, String? reason]) {
    _closeCode = code;
    _closeReason = reason;
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _controller.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  void add(dynamic data) {
    sentMessages.add(data);
    if (autoSetupComplete && data is String && data.contains('"setup"')) {
      scheduleMicrotask(() => emit('{"setupComplete":{}}'));
    }
  }

  @override
  Future<dynamic> close([int? code, String? reason]) {
    _closeCode ??= code;
    _closeReason ??= reason;
    return _controller.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePcmPlayer extends PlatformPcmStreamPlayer {
  @override
  bool get isPlaying => false;
  @override
  Future<void> feedPcm(Uint8List pcmBytes,
      {int sampleRate = 24000,
      int volumePercent = 100,
      String outputDeviceId = ''}) async {}
  @override
  Future<void> stopImmediate() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('1. GeminiLiveDialogSetup 握手与载荷构建测试', () {
    test('构建包含 AUDIO 模态、音色、双向字幕、滑窗压缩与工具声明的 setup 载荷', () {
      final settings = AppSettings(
        pipelineMode: AppConstants.pipelineModeGeminiLive,
        geminiLiveModel: 'gemini-3.8-live',
        geminiLiveVoice: 'Kore',
        enableWebSearch: true,
        enableLightRag: true,
        lightRagBaseUrl: 'http://127.0.0.1:9621',
        enableVisionIntent: true,
        systemPrompt: '你是贴心助手晓漫。',
      );

      final setupMap = GeminiLiveDialogSetup.buildSetupMessage(
        settings: settings,
        sessionResumptionHandle: 'resume_token_123',
      );

      final setup = setupMap['setup'] as Map<String, dynamic>;
      expect(setup['model'], equals('models/gemini-3.8-live'));

      final genCfg = setup['generationConfig'] as Map<String, dynamic>;
      expect(genCfg['responseModalities'], equals(['AUDIO']));
      expect(
        genCfg['speechConfig']['voiceConfig']['prebuiltVoiceConfig']
            ['voiceName'],
        equals('Kore'),
      );

      expect(setup.containsKey('inputAudioTranscription'), isTrue);
      expect(setup.containsKey('outputAudioTranscription'), isTrue);
      expect(
        setup['contextWindowCompression'],
        equals({'slidingWindow': <String, dynamic>{}}),
      );
      expect(
        setup['sessionResumption'],
        equals({'handle': 'resume_token_123'}),
      );

      final realtimeConfig =
          setup['realtimeInputConfig'] as Map<String, dynamic>;
      final aad =
          realtimeConfig['automaticActivityDetection'] as Map<String, dynamic>;
      expect(aad['disabled'], isFalse);
      expect(aad['startOfSpeechSensitivity'], equals('START_SENSITIVITY_HIGH'));
      expect(aad['endOfSpeechSensitivity'], equals('END_SENSITIVITY_LOW'));
      expect(aad['prefixPaddingMs'], equals(300));
      expect(aad['silenceDurationMs'], equals(700));

      final tools = setup['tools'] as List<dynamic>;
      expect(tools.any((t) => (t as Map).containsKey('googleSearch')), isTrue);
      final fnTool = tools.firstWhere(
        (t) => (t as Map).containsKey('functionDeclarations'),
      ) as Map<String, dynamic>;
      final decls = fnTool['functionDeclarations'] as List<dynamic>;
      final names = decls.map((d) => (d as Map)['name']).toList();
      expect(names, containsAll(['lightrag_query', 'capture_photo']));
    });

    test('构建 clientContent 文本消息与历史上下文种子', () {
      final msg = GeminiLiveDialogSetup.buildClientTextMessage(
        '今天天气如何',
        turnComplete: true,
      );
      final clientContent = msg['clientContent'] as Map<String, dynamic>;
      expect(clientContent['turnComplete'], isTrue);
      final turns = clientContent['turns'] as List<dynamic>;
      expect(turns.single['role'], equals('user'));
      expect(turns.single['parts'].single['text'], equals('今天天气如何'));

      final historySeed = GeminiLiveDialogSetup.buildHistorySeedMessage([
        ChatMessage(
            id: '1', role: 'user', content: '你好', timestamp: DateTime(2026)),
        ChatMessage(
            id: '2',
            role: 'assistant',
            content: '你好！有什么可以帮您？',
            timestamp: DateTime(2026)),
      ]);
      expect(historySeed, isNotNull);
      expect(historySeed!['clientContent']['turnComplete'], isFalse);
      expect((historySeed['clientContent']['turns'] as List).length, equals(2));
    });

    test(
        'encodeRealtimeImageMessage 生成符合 Gemini Live 视频流规范的 realtimeInput.video 载荷',
        () {
      final fakeJpeg = Uint8List.fromList([0xFF, 0xD8, 0x01, 0x02]);
      final encoded =
          GeminiLiveDialogSetup.encodeRealtimeImageMessage(fakeJpeg);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded.containsKey('realtimeInput'), isTrue);
      final video = (decoded['realtimeInput'] as Map<String, dynamic>)['video']
          as Map<String, dynamic>;
      expect(video['mimeType'], equals('image/jpeg'));
      expect(video['data'], equals(base64Encode(fakeJpeg)));
      expect(decoded['realtimeInput'].containsKey('mediaChunks'), isFalse);
    });

    test('buildClientTextMessage 附带 imageBytes 时包含 inlineData 与 text', () {
      final fakeJpeg = Uint8List.fromList([0xFF, 0xD8, 0xAA, 0xBB]);
      final msg = GeminiLiveDialogSetup.buildClientTextMessage(
        '分析画面',
        imageBytes: fakeJpeg,
      );
      final clientContent = msg['clientContent'] as Map<String, dynamic>;
      final turns = clientContent['turns'] as List<dynamic>;
      final parts = turns.single['parts'] as List<dynamic>;
      expect(parts.length, equals(2));
      expect(parts[0]['inlineData']['mimeType'], equals('image/jpeg'));
      expect(parts[0]['inlineData']['data'], equals(base64Encode(fakeJpeg)));
      expect(parts[1]['text'], equals('分析画面'));
    });

    test('GeminiLiveDialogSetup 注册 record_background_speech 工具、提示词规则与背景语音消息前缀',
        () {
      final settings = AppSettings(
        pipelineMode: AppConstants.pipelineModeGeminiLive,
        geminiApiKey: 'test_key',
      );

      final tools = GeminiLiveDialogSetup.buildTools(settings);
      final fnTool = tools.firstWhere(
        (t) => t.containsKey('functionDeclarations'),
      );
      final decls = fnTool['functionDeclarations'] as List<dynamic>;
      expect(
        decls.any((d) => d is Map && d['name'] == 'record_background_speech'),
        isTrue,
      );

      final sysPrompt = GeminiLiveDialogSetup.buildSystemInstruction(settings);
      expect(sysPrompt, contains('record_background_speech'));
      expect(sysPrompt, contains('交谈意图判定与背景语音记录规范'));

      final historySeed = GeminiLiveDialogSetup.buildHistorySeedMessage([
        ChatMessage(
          id: '1',
          role: 'user',
          content: '这是一条背景语音',
          timestamp: DateTime(2026),
          isUnintended: true,
        ),
      ]);
      expect(historySeed, isNotNull);
      final turns = historySeed!['clientContent']['turns'] as List<dynamic>;
      expect(
        turns.single['parts'].single['text'],
        equals('[背景信息（无交谈意图）] 这是一条背景语音'),
      );
    });
  });

  group('2. GeminiLiveDialogProtocol 服务端帧解析测试', () {
    test('解析 setupComplete、24kHz PCM 音频块、双向转写、interrupted 及 toolCall', () {
      var setupComplete = false;
      var interrupted = false;
      String? lastInput;
      String? lastOutput;
      String? resumptionHandle;
      final audioChunks = <Uint8List>[];
      final audioRates = <int>[];
      final toolCalls = <GeminiLiveToolCall>[];

      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onSetupComplete: () => setupComplete = true,
        onInterrupted: () => interrupted = true,
        onInputTranscript: (text, {required isFinal}) => lastInput = text,
        onOutputTranscript: (delta, full, {required isFinal}) =>
            lastOutput = full,
        onAudioChunk: (bytes, rate) {
          audioChunks.add(bytes);
          audioRates.add(rate);
        },
        onToolCalls: (calls) => toolCalls.addAll(calls),
        onSessionResumptionUpdate: (handle) => resumptionHandle = handle,
      );

      protocol.handleRawFrame('{"setupComplete":{}}', 1);
      expect(setupComplete, isTrue);

      final rawPcm = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      protocol.handleRawFrame(
        '{"serverContent":{"inputTranscription":{"text":"帮我拍张照"},'
        '"outputTranscription":{"text":"好的，马上拍。"},'
        '"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"${base64Encode(rawPcm)}"}}]},'
        '"turnComplete":true}}',
        1,
      );
      expect(lastInput, equals('帮我拍张照'));
      expect(lastOutput, equals('好的，马上拍。'));
      expect(audioChunks.single, equals(rawPcm));
      expect(audioRates.single, equals(24000));

      protocol.handleRawFrame('{"serverContent":{"interrupted":true}}', 1);
      expect(interrupted, isTrue);

      protocol.handleRawFrame(
        '{"toolCall":{"functionCalls":[{"id":"call_1","name":"capture_photo","args":{"reason":"用户要求拍照"}}]}}',
        1,
      );
      expect(toolCalls.length, equals(1));
      expect(toolCalls.single.id, equals('call_1'));
      expect(toolCalls.single.name, equals('capture_photo'));

      protocol.handleRawFrame(
        '{"sessionResumptionUpdate":{"resumable":true,"newHandle":"handle_xyz"}}',
        1,
      );
      expect(resumptionHandle, equals('handle_xyz'));
    });

    test('协议层：interrupted 后吸收迟到的同文 inputTranscription 与被打断轮次收尾 turnComplete',
        () {
      final inputTranscripts = <String>[];
      final outputTranscripts = <String>[];
      var turnCompleteCount = 0;
      var interruptedCount = 0;

      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onInterrupted: () => interruptedCount++,
        onInputTranscript: (text, {required isFinal}) =>
            inputTranscripts.add(text),
        onOutputTranscript: (delta, full, {required isFinal}) =>
            outputTranscripts.add(full),
        onTurnComplete: (inText, outText) => turnCompleteCount++,
      );

      // 1. 用户输入 "那您现在"
      protocol.handleRawFrame(
          '{"serverContent":{"inputTranscription":{"text":"那您现在"}}}', 1);
      expect(inputTranscripts, equals(['那您现在']));

      // 2. 助手开始输出
      protocol.handleRawFrame(
          '{"serverContent":{"outputTranscription":{"text":"您好，我在听。"}}}', 1);
      expect(outputTranscripts, equals(['您好，我在听。']));

      // 3. 服务端下发打断
      protocol.handleRawFrame('{"serverContent":{"interrupted":true}}', 1);
      expect(interruptedCount, equals(1));

      // 4. 服务端迟到下发同文 inputTranscription
      protocol.handleRawFrame(
          '{"serverContent":{"inputTranscription":{"text":"那您现在"}}}', 1);
      // 应被过滤，不触发 onInputTranscript
      expect(inputTranscripts.length, equals(1));

      // 5. 服务端下发被打断轮次的收尾 turnComplete
      protocol.handleRawFrame('{"serverContent":{"turnComplete":true}}', 1);
      // 应被吸收，不触发 onTurnComplete
      expect(turnCompleteCount, equals(0));
    });

    test('协议层：interrupted 后立即收到新一轮输入 "你"，随后的上一轮收尾 turnComplete 不会冲掉新一轮输入', () {
      final inputTranscripts = <String>[];
      final outputTranscripts = <String>[];
      var turnCompleteFinalInput = '';
      var turnCompleteFinalOutput = '';

      final protocol = GeminiLiveDialogProtocol(
        activeConnectionId: () => 1,
        onInputTranscript: (text, {required isFinal}) =>
            inputTranscripts.add(text),
        onOutputTranscript: (delta, full, {required isFinal}) =>
            outputTranscripts.add(full),
        onTurnComplete: (inText, outText) {
          turnCompleteFinalInput = inText;
          turnCompleteFinalOutput = outText;
        },
      );

      // 上一轮助手回答中
      protocol.handleRawFrame(
          '{"serverContent":{"outputTranscription":{"text":"上一轮回答"}}}', 1);

      // 1. 收到打断
      protocol.handleRawFrame('{"serverContent":{"interrupted":true}}', 1);

      // 2. 用户立即开始新一轮输入 "你"
      protocol.handleRawFrame(
          '{"serverContent":{"inputTranscription":{"text":"你"}}}', 1);
      expect(inputTranscripts, contains('你'));
      expect(protocol.currentInputText, equals('你'));

      // 3. 上一轮收尾 turnComplete: true 到达
      protocol.handleRawFrame('{"serverContent":{"turnComplete":true}}', 1);
      // 验证 "你" 没有被收尾清空！
      expect(protocol.currentInputText, equals('你'));
      expect(turnCompleteFinalInput, isEmpty);

      // 4. 新一轮助手输出 "我在"
      protocol.handleRawFrame(
          '{"serverContent":{"outputTranscription":{"text":"我在"}}}', 1);
      expect(protocol.currentOutputText, equals('我在'));

      // 5. 新一轮正常完成 turnComplete: true
      protocol.handleRawFrame('{"serverContent":{"turnComplete":true}}', 1);
      expect(turnCompleteFinalInput, equals('你'));
      expect(turnCompleteFinalOutput, equals('我在'));
    });
  });

  group('3. GeminiLivePcm.conditionLiveSamples 蓝牙/低增益麦克风包络自适应动态增益测试', () {
    setUp(() {
      GeminiLivePcm.resetConditioner();
    });

    Float32List sine(int n, double amp, double freq) =>
        Float32List.fromList(List.generate(
            n, (i) => amp * math.sin(2 * math.pi * freq * i / 16000)));
    double rms(Float32List s) =>
        math.sqrt(s.fold<double>(0.0, (acc, v) => acc + v * v) / s.length);

    test('低音量蓝牙人声（0.002 振幅）在待机与播放期均放大到目标响度支持打断', () {
      final quietSpeech = sine(1600, 0.002, 300);
      GeminiLivePcm.resetConditioner();
      final conditionedIdle = GeminiLivePcm.conditionLiveSamples(quietSpeech);
      expect(conditionedIdle, isNot(same(quietSpeech)));
      expect(rms(conditionedIdle), greaterThan(0.03));

      GeminiLivePcm.resetConditioner();
      final conditionedPlaying = GeminiLivePcm.conditionLiveSamples(
        quietSpeech,
        isPlayingOutput: true,
      );
      expect(conditionedPlaying, isNot(same(quietSpeech)));
      expect(rms(conditionedPlaying), greaterThan(0.03));
    });

    test('Hangover 尾音保持窗跨帧维持辅音增益，避免词内轻辅音被削为 1.0x', () {
      final vowelFrame = sine(1600, 0.0025, 300);
      final consonantFrame = sine(1600, 0.00035, 1200);

      GeminiLivePcm.conditionLiveSamples(vowelFrame);
      expect(GeminiLivePcm.isInSpeechHangover, isTrue);

      final conditionedConsonant =
          GeminiLivePcm.conditionLiveSamples(consonantFrame);
      expect(conditionedConsonant, isNot(same(consonantFrame)));
      final maxAmp = conditionedConsonant.fold<double>(
          0.0, (m, s) => math.max(m, s.abs()));
      expect(maxAmp / 0.00035, greaterThan(10.0));
    });

    test('空闲底噪在未激活状态下保持 1.0x 原样透传不放大', () {
      final idleNoise = sine(1600, 0.0003, 200);
      expect(GeminiLivePcm.conditionLiveSamples(idleNoise), same(idleNoise));

      final playingNoise = sine(1600, 0.0005, 200);
      expect(
        GeminiLivePcm.conditionLiveSamples(playingNoise, isPlayingOutput: true),
        same(playingNoise),
      );
    });

    test('正常响度人声（0.25 振幅，rms > 0.085）保持原样透传', () {
      final loudSpeech = sine(1600, 0.25, 300);
      expect(GeminiLivePcm.conditionLiveSamples(loudSpeech), same(loudSpeech));
    });

    test('回声门限：在播放回声窗内，低振幅回声（0.0008 振幅，rms ~0.00056）静音输出且不触发打断', () {
      var bargeInTriggered = false;
      final echoSamples = sine(1600, 0.0008, 1000);
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

    test('本地打断：在播放回声窗内，连续谐波人声（0.008 峰值谐波，>2400 采样）触发插话并回放预卷', () {
      // Linux's processed capture path retains sensitive close-talk detection.
      GeminiLivePcm.debugForceWindowsEchoProfile = false;
      GeminiLivePcm.debugForceMobileEchoProfile = false;
      var bargeInTriggered = false;
      final speechSamples = Float32List.fromList(List.generate(3200, (i) {
        final t = 2 * math.pi * 200 * i / 16000;
        return 0.006 * math.sin(t) + 0.003 * math.sin(2 * t);
      }));

      final outBytes = GeminiLivePcm.processUplinkSamples(
        speechSamples,
        isInPlaybackEchoZone: true,
        onLocalBargeInTriggered: () => bargeInTriggered = true,
      );

      expect(bargeInTriggered, isTrue);
      expect(GeminiLivePcm.isBargeInActive, isTrue);
      expect(outBytes.length, greaterThanOrEqualTo(speechSamples.length * 2));
      expect(outBytes.any((b) => b != 0), isTrue);
    });
  });

  group('4. AssistantEngine & GeminiLiveTurnCoordinator 全双工联动测试', () {
    tearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

    AssistantEngine createEngine(NullGeminiLiveSessionPort fakeLive,
        [AppSettings? s]) {
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      final engine = AssistantEngine(
        settings: s ??
            AppSettings(
              pipelineMode: AppConstants.pipelineModeGeminiLive,
              geminiApiKey: 'test-key',
              geminiLiveModel: 'gemini-3.8-live',
              geminiLiveVoice: 'Aoede',
            ),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());
      return engine;
    }

    test('production wiring honors the configured tool progress interval', () {
      final engine = createEngine(_FakeGeminiLiveSession(),
          AppSettings(openCodeProgressIntervalSeconds: 23));
      expect(
          engine.dialogueCoordinator.geminiLiveCoordinator.toolProgressInterval,
          const Duration(seconds: 23));
    });

    test('Gemini Live 模式下免唤醒词、双向字幕实时上屏、服务端打断瞬时响应', () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      // Gemini Live 全双工模式下免唤醒词
      expect(engine.isWakeWordRequired, isFalse);

      final geminiCoord = engine.dialogueCoordinator.geminiLiveCoordinator;
      await geminiCoord.onMicListeningChanged(true);
      expect(fakeLive.connectCalls, equals(1));
      expect(engine.status, equals(AssistantStatus.listeningContent));

      // 模拟用户说话实时转写上屏
      fakeLive.onInputTranscription?.call('今天天气怎么样', isFinal: true);
      expect(engine.liveTranscript, equals('今天天气怎么样'));
      expect(engine.messages.length, equals(2));
      expect(engine.messages.first.content, equals('今天天气怎么样'));

      // 模拟模型开始语音回复与输出字幕流式更新
      fakeLive.onModelTurnStarted?.call();
      expect(engine.status, equals(AssistantStatus.playing));

      fakeLive.onOutputTranscription?.call(
        '今天晴朗，',
        '今天晴朗，气温适宜。',
        isFinal: false,
      );
      expect(engine.messages.last.content, equals('今天晴朗，气温适宜。'));
      expect(
        engine.dialogueCoordinator.currentSpeakingReply,
        equals('今天晴朗，气温适宜。'),
      );

      // 模拟用户在模型说话中途开口打断 (serverContent.interrupted)
      fakeLive.onInterrupted?.call();
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.dialogueCoordinator.currentSpeakingReply, isEmpty);

      // 模拟直接发送文本消息走 Gemini Live 会话
      await engine.sendTextMessage('再帮我查一下明天温度');
      expect(fakeLive.sentTexts, contains('再帮我查一下明天温度'));
    });

    test(
        'GeminiLiveTurnCoordinator 收到 onBackgroundSpeechDetected：标记 isUnintended、移除占位符并重置为 idle',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      final geminiCoord = engine.dialogueCoordinator.geminiLiveCoordinator;
      await geminiCoord.onMicListeningChanged(true);

      String? decisionDecision;
      bool? decisionShouldReply;
      String? decisionIntent;
      geminiCoord.onSpeechDecision = ({
        forText,
        required llmDecision,
        shouldReply,
        intent,
        detail,
      }) {
        decisionDecision = llmDecision;
        decisionShouldReply = shouldReply;
        decisionIntent = intent;
      };

      // 1. 用户开口但实际为旁白或打电话
      fakeLive.onInputTranscription?.call('老板这个报价我明天发您', isFinal: false);
      expect(engine.messages.length, equals(2));
      expect(engine.messages.first.isUnintended, isFalse);

      // 2. 服务端识别出无交谈意图，触发 onBackgroundSpeechDetected
      fakeLive.onBackgroundSpeechDetected?.call('老板这个报价我明天发您', '与身边同事打电话');

      // 验证：用户消息被标记为 isUnintended: true，空白助手占位符被清除
      expect(engine.messages.length, equals(1));
      expect(engine.messages.single.isUnintended, isTrue);
      expect(engine.messages.single.content, equals('老板这个报价我明天发您'));
      expect(decisionShouldReply, isFalse);
      expect(decisionIntent, equals('ignore'));
      expect(decisionDecision, equals('无需回答 (背景信息)'));
      expect(engine.status, equals(AssistantStatus.idle));

      // 3. 随后的迟到 modelTurnStarted 与 outputTranscription 被忽略
      fakeLive.onModelTurnStarted?.call();
      expect(engine.messages.length, equals(1));
      fakeLive.onOutputTranscription?.call('好的', '好的', isFinal: true);
      expect(engine.messages.length, equals(1));

      // 4. 轮次结束，状态保持 idle
      fakeLive.onTurnCompleted?.call();
      expect(engine.status, equals(AssistantStatus.idle));
    });

    test(
        'DialogueIntentCoordinator.previewVoice 分流路由：Gemini Live 音色走 Live 会话，标准音色走 TtsPort',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final fakeTts = _FakeTtsPort();
      final engine = createEngine(
        fakeLive,
        AppSettings(
          pipelineMode: AppConstants.pipelineModeCascade,
          geminiApiKey: 'test-key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveVoice: 'Aoede',
          edgeVoice: 'zh-CN-XiaoxiaoNeural',
        ),
      );
      engine.dialogueCoordinator.ttsService = fakeTts;

      // 1. 传入 Gemini Live 30 预置音色之一（例如 Fenrir）
      await engine.dialogueCoordinator.previewVoice(
        voice: 'Fenrir',
        text: '你好，我是 Fenrir。',
      );
      expect(fakeLive.previewVoiceCalls, equals(1));
      expect(fakeLive.lastPreviewVoice, equals('Fenrir'));
      expect(fakeLive.lastPreviewText, equals('你好，我是 Fenrir。'));
      expect(fakeTts.previewVoiceCalls, equals(0));

      // 2. 传入标准 TTS 音色（例如 zh-CN-XiaoxiaoNeural）
      await engine.dialogueCoordinator.previewVoice(
        voice: 'zh-CN-XiaoxiaoNeural',
        text: '你好，我是晓晓。',
      );
      expect(fakeTts.previewVoiceCalls, equals(1));
      expect(fakeTts.lastVoice, equals('zh-CN-XiaoxiaoNeural'));
      expect(fakeTts.lastText, equals('你好，我是晓晓。'));
      expect(fakeLive.previewVoiceCalls, equals(1));

      // 3. 当设置为 Gemini Live 模式且未指定音色时，自动路由到 Live 会话
      engine.dialogueCoordinator.updateSettings(
        engine.settings.copyWithMap({
          'pipelineMode': AppConstants.pipelineModeGeminiLive,
          'geminiLiveVoice': 'Zephyr',
        }),
      );
      await engine.dialogueCoordinator.previewVoice(text: 'Live 模式默认音色试听');
      expect(fakeLive.previewVoiceCalls, equals(2));
      expect(fakeLive.lastPreviewVoice, equals('Zephyr'));
      expect(fakeLive.lastPreviewText, equals('Live 模式默认音色试听'));
    });

    test('GeminiLiveDialogService.previewVoice 当 API Key 为空时抛出 StateError',
        () async {
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: '',
        ),
      );
      expect(
        () => service.previewVoice(voice: 'Aoede'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Gemini API Key 为空'),
        )),
      );
    });

    test('sendClientText 时服务端返回 interrupted 不会孤立文本气泡也不会产生虚假（语音输入）气泡', () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      // 客户端发送文本 '九点'
      await engine.sendTextMessage('九点');
      expect(engine.messages.length, equals(2));
      expect(engine.messages[0].content, equals('九点'));
      expect(engine.messages[1].content, isEmpty);

      // 服务端因为上一轮还在发声，先返回 interrupted: true
      fakeLive.onInterrupted?.call();

      // 验证未产生重置，气泡数量依然为 2，没有多余的 （语音输入）
      expect(engine.messages.length, equals(2));
      expect(engine.messages[0].content, equals('九点'));

      // 服务端开始回答这一轮的 clientText
      fakeLive.onOutputTranscription?.call('现在是九点整。', '现在是九点整。', isFinal: true);
      fakeLive.onTurnCompleted?.call();

      expect(engine.messages.length, equals(2));
      expect(engine.messages[0].content, equals('九点'));
      expect(engine.messages[1].content, equals('现在是九点整。'));
      expect(engine.messages.any((m) => m.content.contains('（语音输入）')), isFalse);
    });

    test('Gemini Live 模式下麦克风测试触发 TranscriptUpdatedEvent 时更新 micTestHistory',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      engine.voiceCoordinator.isMicTesting = true;
      MicTestUpdatedEvent? receivedEvent;
      final sub = engine.events.listen((e) {
        if (e is MicTestUpdatedEvent) {
          receivedEvent = e;
        }
      });
      addTearDown(() => sub.cancel());

      // 模拟实时语音转写完成
      fakeLive.onInputTranscription?.call('测试麦克风拾音', isFinal: true);
      await pumpEventQueue();

      expect(engine.micTestText, equals('测试麦克风拾音'));
      expect(engine.micTestHistory.isNotEmpty, isTrue);
      expect(engine.micTestHistory.first['text'], equals('测试麦克风拾音'));
      expect(engine.micTestHistory.first['engine'], equals('Gemini 3.8 Live'));
      expect(receivedEvent, isNotNull);
      expect(receivedEvent!.text, equals('测试麦克风拾音'));
      expect(receivedEvent!.engine, equals('Gemini 3.8 Live'));
    });

    test('打断后迟到的同文 inputTranscription 与收尾 turnComplete 不会产生重复气泡或空助手占位',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);
      fakeLive.onInputTranscription?.call('那您现在', isFinal: false);
      fakeLive.onModelTurnStarted?.call();
      fakeLive.onOutputTranscription
          ?.call('您好，我在听。', '您好，我在听。', isFinal: false);
      expect(engine.messages.length, equals(2));

      fakeLive.onInterrupted?.call();
      expect(engine.status, equals(AssistantStatus.listeningContent));
      expect(engine.messages.last.content, equals('您好，我在听。'));

      // 迟到的同文 inputTranscription 与收尾 turnComplete
      fakeLive.onInputTranscription?.call('那您现在', isFinal: false);
      fakeLive.onTurnCompleted?.call();

      expect(engine.messages.length, equals(2));
      expect(engine.messages[0].content, equals('那您现在'));
      expect(engine.messages[1].content, equals('您好，我在听。'));
    });

    test('打断后立即收到新输入 "你"，随后到达的上一轮收尾 turnComplete 不会冲掉新轮次', () async {
      final fakeLive = _FakeGeminiLiveSession();
      final engine = createEngine(fakeLive);

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);
      fakeLive.onInputTranscription?.call('你好', isFinal: false);
      fakeLive.onModelTurnStarted?.call();
      fakeLive.onOutputTranscription?.call('你好呀！', '你好呀！', isFinal: false);

      fakeLive.onInterrupted?.call();
      fakeLive.onInputTranscription?.call('你', isFinal: false);
      expect(engine.messages.length, equals(4));
      expect(engine.messages[2].content, equals('你'));
      expect(engine.messages[3].content, isEmpty);

      fakeLive.onOutputTranscription?.call('我在呢。', '我在呢。', isFinal: false);
      fakeLive.onTurnCompleted?.call();
      expect(engine.messages.length, equals(4));
      expect(engine.messages[2].content, equals('你'));
      expect(engine.messages[3].content, equals('我在呢。'));
    });

    test(
        '当 invoke_opencode 或 call_custom_tool 触发时若 Gemini Live 未开口，自动触发拟人化前置垫话且气泡展示状态',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final fakeTts = _FakeTtsPort();
      final engine = createEngine(fakeLive);
      engine.dialogueCoordinator.ttsService = fakeTts;

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);

      // 1. 测试 invoke_opencode 前置垫话兜底
      fakeLive.onInputTranscription?.call('帮我写一个股票查询工具', isFinal: true);
      fakeLive.onToolCall?.call('invoke_opencode', 'query_stock');

      expect(fakeTts.spokenTexts.length, equals(1));
      expect(
        fakeTts.spokenTexts.first,
        contains('好的，我先用 OpenCode 帮你构建并执行 query_stock，可能需要一点时间，请稍候。'),
      );
      expect(
        engine.messages.last.content,
        equals('正在调用 OpenCode 构建工具：query_stock...'),
      );
      expect(
        engine.statusHint,
        equals('正在调用 OpenCode 构建工具：query_stock...'),
      );

      // 2. 测试 call_custom_tool 前置垫话兜底
      fakeTts.spokenTexts.clear();
      fakeLive.onTurnCompleted?.call();
      fakeLive.onInputTranscription?.call('查询北京天气', isFinal: true);
      fakeLive.onToolCall?.call('call_custom_tool', 'get_weather');

      expect(fakeTts.spokenTexts.length, equals(1));
      expect(
        fakeTts.spokenTexts.first,
        contains('好的，我这就调用 get_weather 工具帮你处理，请稍等。'),
      );
      expect(
        engine.messages.last.content,
        equals('正在调用工具：get_weather...'),
      );
      expect(
        engine.statusHint,
        equals('正在调用工具：get_weather...'),
      );
    });

    test('当 Gemini Live 在 invoke_opencode 前已开口发声，保留前期字幕且 t=0 不重复垫话', () async {
      final fakeLive = _FakeGeminiLiveSession();
      final fakeTts = _FakeTtsPort();
      final engine = createEngine(fakeLive);
      engine.dialogueCoordinator.ttsService = fakeTts;

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);

      fakeLive.onInputTranscription?.call('帮我算一下这组数据', isFinal: true);
      fakeLive.onModelTurnStarted?.call();
      fakeLive.onOutputTranscription?.call(
        '好的，我先看一下数据结构。',
        '好的，我先看一下数据结构。',
        isFinal: false,
      );

      // Gemini Live 触发工具调用
      fakeLive.onToolCall?.call('invoke_opencode', 'calc_data');

      // 验证未重复发声垫话（Gemini 自身已开口）
      expect(fakeTts.spokenTexts, isEmpty);

      // 验证气泡无损拼接：保留已有回复并在尾部追加工具执行状态
      expect(
        engine.messages.last.content,
        equals('好的，我先看一下数据结构。\n\n正在调用 OpenCode 构建工具：calc_data...'),
      );
    });

    test('invoke_opencode 长耗时下触发周期性拟人化进度汇报并在 outputTranscription 恢复后停止',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      final fakeTts = _FakeTtsPort();
      final engine = createEngine(fakeLive);
      engine.dialogueCoordinator.ttsService = fakeTts;
      engine.dialogueCoordinator.geminiLiveCoordinator.toolProgressInterval =
          const Duration(milliseconds: 60);

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);

      fakeLive.onInputTranscription?.call('生成复杂可视化图表', isFinal: true);
      fakeLive.onToolCall?.call('invoke_opencode', 'draw_chart');

      // t=0 前置垫话
      expect(fakeTts.spokenTexts.length, equals(1));

      // 第一次 tick (~60ms)
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeTts.spokenTexts.length, equals(2));
      expect(
        fakeTts.spokenTexts[1],
        contains('还在帮你构建 draw_chart 工具，稍微有点复杂，请再稍等一下哦。'),
      );
      expect(engine.messages.last.content, contains('编写并调试「draw_chart」'));
      expect(engine.messages.last.content, matches(RegExp(r'已经进行了约 \d+ 秒')));

      // 第二次 tick (~120ms)
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeTts.spokenTexts.length, equals(3));
      expect(
        fakeTts.spokenTexts[2],
        contains('工具还在编写和测试中，马上就好，请稍候。'),
      );
      expect(
        engine.messages.last.content,
        matches(RegExp(r'仍在努力构建「draw_chart」中（已耗时约 \d+ 秒）')),
      );

      // 工具执行完毕，Gemini Live 恢复输出字幕
      fakeLive.onOutputTranscription?.call(
        '图表已成功生成并渲染完成。',
        '图表已成功生成并渲染完成。',
        isFinal: true,
      );
      expect(engine.messages.last.content, equals('图表已成功生成并渲染完成。'));
      expect(fakeTts.stopCalls, greaterThan(0));

      // 再次等待一段时间，验证周期性计时器已被取消不再发声
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeTts.spokenTexts.length, equals(3));
    });

    test('打断或直接说话时清理长耗时进度计时器与正在播报的垫话', () async {
      final fakeLive = _FakeGeminiLiveSession();
      final fakeTts = _FakeTtsPort();
      final engine = createEngine(fakeLive);
      engine.dialogueCoordinator.ttsService = fakeTts;
      engine.dialogueCoordinator.geminiLiveCoordinator.toolProgressInterval =
          const Duration(milliseconds: 60);

      await engine.dialogueCoordinator.geminiLiveCoordinator
          .onMicListeningChanged(true);

      fakeLive.onInputTranscription?.call('生成报表', isFinal: true);
      fakeLive.onToolCall?.call('call_custom_tool', 'gen_report');

      expect(fakeTts.spokenTexts.length, equals(1));

      // 模拟用户打断
      fakeLive.onInterrupted?.call();
      expect(fakeTts.stopCalls, greaterThan(0));

      // 验证计时器已取消，不再触发后续 tick
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeTts.spokenTexts.length, equals(1));
    });
  });

  group('5. GeminiLiveDialogService 视觉多模态与 ToolCall 生命周期测试', () {
    test(
        'capture_photo 执行时发送 toolResponse 与 inlineData clientContent，并抑制运行中的 interim turnComplete',
        () async {
      final fakeSocket = _FakeLiveWebSocket();
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      var turnCompleteCount = 0;
      service.onTurnCompleted = () => turnCompleteCount++;

      final photoCompleter = Completer<CameraCaptureResult?>();
      final fakeJpeg = Uint8List.fromList([0xFF, 0xD8, 0x11, 0x22]);
      service.onCapturePhoto = () => photoCompleter.future;

      expect(await service.connect(), isTrue);

      // 服务端下发 capture_photo 的 toolCall
      fakeSocket.emit(
          '{"toolCall":{"functionCalls":[{"id":"call_cam_1","name":"capture_photo","args":{}}]}}');
      await pumpEventQueue();

      // 服务端在 toolCall 后立即下发 interim turnComplete: true
      fakeSocket.emit('{"serverContent":{"turnComplete":true}}');
      await pumpEventQueue();

      // 验证：拍照工具执行中，interim turnComplete 被抑制，未触发 onTurnCompleted
      expect(turnCompleteCount, equals(0));

      // 拍照完成并返回图像
      photoCompleter.complete(CameraCaptureResult(
        imageBytes: fakeJpeg,
        filePath: 'test.jpg',
      ));
      await pumpEventQueue();

      // 验证 sentMessages：
      // 1. setup 消息
      // 2. toolResponse（结果为 '拍照成功'）
      // 3. 紧随其后的 clientContent（包含 inlineData 与提示文本）
      final messages = fakeSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();

      final toolResponseMsg =
          messages.firstWhere((m) => m.containsKey('toolResponse'));
      final fnResponses =
          toolResponseMsg['toolResponse']['functionResponses'] as List;
      expect(fnResponses.single['id'], equals('call_cam_1'));
      expect(fnResponses.single['response']['result'], equals('拍照成功'));

      final toolRespIdx = messages.indexOf(toolResponseMsg);
      final clientContentMsg = messages[toolRespIdx + 1];
      expect(clientContentMsg.containsKey('clientContent'), isTrue);

      final parts =
          clientContentMsg['clientContent']['turns'][0]['parts'] as List;
      expect(parts[0]['inlineData']['mimeType'], equals('image/jpeg'));
      expect(parts[0]['inlineData']['data'], equals(base64Encode(fakeJpeg)));
      expect(parts[1]['text'], contains('这是刚刚拍下的现场照片'));

      // 验证未在 toolResponse 前发送单独的 realtimeInput.video
      expect(messages.any((m) => m.containsKey('realtimeInput')), isFalse);

      // 随后服务端下发最终的 turnComplete，此时 pendingToolCalls 为 0，应正常触发 onTurnCompleted
      fakeSocket.emit('{"serverContent":{"turnComplete":true}}');
      await pumpEventQueue();
      expect(turnCompleteCount, equals(1));
    });

    test('sendClientText 附带 imageBytes 时作为单条 clientContent(inlineData) 发送',
        () async {
      final fakeSocket = _FakeLiveWebSocket();
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      await service.connect();
      final initialCount = fakeSocket.sentMessages.length;

      final photoBytes = Uint8List.fromList([0xFF, 0xD8, 0x33, 0x44]);
      await service.sendClientText('看这张图', imageBytes: photoBytes);

      // 应当只追加一条消息 (clientContent)，而非分立发送 realtimeInput.video
      expect(fakeSocket.sentMessages.length, equals(initialCount + 1));
      final lastMsg = jsonDecode(fakeSocket.sentMessages.last.toString())
          as Map<String, dynamic>;
      expect(lastMsg.containsKey('clientContent'), isTrue);
      expect(lastMsg.containsKey('realtimeInput'), isFalse);

      final parts = lastMsg['clientContent']['turns'][0]['parts'] as List;
      expect(parts[0]['inlineData']['data'], equals(base64Encode(photoBytes)));
      expect(parts[1]['text'], equals('看这张图'));
    });

    test('record_background_speech 工具触发时抑制音频输出并派发 onBackgroundSpeechDetected',
        () async {
      final fakeSocket = _FakeLiveWebSocket();
      final fakePlayer = _FakePcmPlayer();
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          enableTtsPlayback: true,
        ),
        pcmPlayer: fakePlayer,
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      String? bgText, bgReason;
      service.onBackgroundSpeechDetected = (t, r) {
        bgText = t;
        bgReason = r;
      };

      await service.connect();

      // 下发 record_background_speech 工具调用
      fakeSocket.emit(
          '{"toolCall":{"functionCalls":[{"id":"call_bg_1","name":"record_background_speech","args":{"text":"喂，你在哪呢","reason":"打手机"}}]}}');
      await pumpEventQueue();

      expect(bgText, equals('喂，你在哪呢'));
      expect(bgReason, equals('打手机'));

      // 验证 toolResponse 发送回云端
      final lastMsg = jsonDecode(fakeSocket.sentMessages.last.toString())
          as Map<String, dynamic>;
      expect(lastMsg.containsKey('toolResponse'), isTrue);
      final fnResp = lastMsg['toolResponse']['functionResponses'] as List;
      expect(fnResp.single['name'], equals('record_background_speech'));
      expect(fnResp.single['response']['result'], contains('已记录背景语音'));

      // 验证在同一轮次中若云端下发了模型音频，被 suppressCurrentTurnAudio 拦截
      var audioChunkReceived = false;
      service.onAudioOutputChunk = (_) => audioChunkReceived = true;
      fakeSocket.emit(
          '{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AA=="}}]}}}');
      await pumpEventQueue();
      expect(audioChunkReceived, isFalse);
    });
  });

  group('6. WebSocket 关闭原因与防握手重连风暴测试', () {
    test('服务端关闭连接时透传 closeReason 和 closeCode 到 lastError、onServerError 及状态提示',
        () async {
      final fakeSocket = _FakeLiveWebSocket(autoSetupComplete: false);
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => fakeSocket,
      );
      addTearDown(() => service.dispose());

      String? serverError;
      String? statusHint;
      service.onServerError = (msg) => serverError = msg;
      service.onStatusHintChanged = (hint) => statusHint = hint;

      final connectFuture = service.connect();
      await pumpEventQueue();

      fakeSocket.closeFromServer(
          1008, 'API key not valid. Please pass a valid API key.');
      final ok = await connectFuture;

      expect(ok, isFalse);
      expect(service.lastError, contains('1008'));
      expect(service.lastError, contains('API key not valid'));
      expect(serverError, contains('1008'));
      expect(serverError, contains('API key not valid'));
      expect(statusHint, contains('1008'));
      expect(statusHint, contains('API key not valid'));
    });

    test('握手失败后 feedAudioSamples 抑制重连风暴，遵循 2s 退避机制而非每音频帧触发重连', () async {
      var connectAttempts = 0;
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async {
          connectAttempts++;
          final s = _FakeLiveWebSocket(autoSetupComplete: false);
          scheduleMicrotask(
              () => s.closeFromServer(1008, 'Spending cap exceeded'));
          return s;
        },
      );
      addTearDown(() => service.dispose());

      final ok = await service.connect();
      expect(ok, isFalse);
      expect(connectAttempts, equals(1));

      // 模拟高频音频帧（如 50 帧连续输入）
      final audioSamples = Float32List(160);
      for (var i = 0; i < 50; i++) {
        service.feedAudioSamples(audioSamples);
      }
      await pumpEventQueue();

      // 验证：连接尝试次数依然为 1，音频帧未触发任何重连风暴
      expect(connectAttempts, equals(1));
    });
  });
}
