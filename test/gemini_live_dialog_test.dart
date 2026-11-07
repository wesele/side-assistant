import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/ports/gemini_live_session_port.dart';
import 'package:side_assistant/core/ports/tts_port.dart';
import 'package:side_assistant/services/speech/gemini_live_dialog_service.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_protocol.dart';
import 'package:side_assistant/services/speech/support/gemini_live_dialog_setup.dart';
import 'package:side_assistant/services/speech/support/gemini_live_pcm.dart';

class _FakeGeminiLiveSession extends NullGeminiLiveSessionPort {
  bool _connected = false;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int stopSpeakingCalls = 0;
  int fedAudioChunks = 0;
  final List<String> sentTexts = [];
  bool? lastResetSessionFlag;
  int previewVoiceCalls = 0;
  String? lastPreviewVoice;
  String? lastPreviewText;

  @override
  bool get isReady => _connected;
  @override
  bool get isActive => _connected;
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
  String? lastVoice;
  String? lastText;

  @override
  Future<void> previewVoice({
    required String voice,
    required String text,
  }) async {
    previewVoiceCalls++;
    lastVoice = voice;
    lastText = text;
  }
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

      protocol.handleRawFrame(
        jsonEncode({'setupComplete': <String, dynamic>{}}),
        1,
      );
      expect(setupComplete, isTrue);

      final rawPcm = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {
            'inputTranscription': {'text': '帮我拍张照'},
            'outputTranscription': {'text': '好的，马上拍。'},
            'modelTurn': {
              'parts': [
                {
                  'inlineData': {
                    'mimeType': 'audio/pcm;rate=24000',
                    'data': base64Encode(rawPcm),
                  },
                },
              ],
            },
            'turnComplete': true,
          },
        }),
        1,
      );
      expect(lastInput, equals('帮我拍张照'));
      expect(lastOutput, equals('好的，马上拍。'));
      expect(audioChunks.single, equals(rawPcm));
      expect(audioRates.single, equals(24000));

      protocol.handleRawFrame(
        jsonEncode({
          'serverContent': {'interrupted': true},
        }),
        1,
      );
      expect(interrupted, isTrue);

      protocol.handleRawFrame(
        jsonEncode({
          'toolCall': {
            'functionCalls': [
              {
                'id': 'call_1',
                'name': 'capture_photo',
                'args': {'reason': '用户要求拍照'},
              },
            ],
          },
        }),
        1,
      );
      expect(toolCalls.length, equals(1));
      expect(toolCalls.single.id, equals('call_1'));
      expect(toolCalls.single.name, equals('capture_photo'));

      protocol.handleRawFrame(
        jsonEncode({
          'sessionResumptionUpdate': {
            'resumable': true,
            'newHandle': 'handle_xyz',
          },
        }),
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

    test('低音量蓝牙人声（0.002 振幅）在待机与播放期均放大到目标响度支持打断', () {
      final quietSpeech = Float32List(1600);
      for (var i = 0; i < quietSpeech.length; i++) {
        quietSpeech[i] =
            (0.002 * math.sin(2 * math.pi * 300 * i / 16000)).toDouble();
      }

      // isPlayingOutput: false
      GeminiLivePcm.resetConditioner();
      final conditionedIdle = GeminiLivePcm.conditionLiveSamples(quietSpeech);
      expect(conditionedIdle, isNot(same(quietSpeech)));
      double sumSq = 0.0;
      for (final s in conditionedIdle) {
        sumSq += s * s;
      }
      final rmsIdle = math.sqrt(sumSq / conditionedIdle.length);
      expect(rmsIdle, greaterThan(0.03));

      // isPlayingOutput: true (打断场景)
      GeminiLivePcm.resetConditioner();
      final conditionedPlaying = GeminiLivePcm.conditionLiveSamples(
        quietSpeech,
        isPlayingOutput: true,
      );
      expect(conditionedPlaying, isNot(same(quietSpeech)));
      sumSq = 0.0;
      for (final s in conditionedPlaying) {
        sumSq += s * s;
      }
      final rmsPlaying = math.sqrt(sumSq / conditionedPlaying.length);
      expect(rmsPlaying, greaterThan(0.03));
    });

    test('Hangover 尾音保持窗跨帧维持辅音增益，避免词内轻辅音被削为 1.0x', () {
      final vowelFrame = Float32List(1600);
      for (var i = 0; i < vowelFrame.length; i++) {
        vowelFrame[i] =
            (0.0025 * math.sin(2 * math.pi * 300 * i / 16000)).toDouble();
      }
      final consonantFrame = Float32List(1600);
      for (var i = 0; i < consonantFrame.length; i++) {
        consonantFrame[i] =
            (0.00035 * math.sin(2 * math.pi * 1200 * i / 16000)).toDouble();
      }

      // 1. 元音帧激活包络并建立增益
      GeminiLivePcm.conditionLiveSamples(vowelFrame);
      expect(GeminiLivePcm.isInSpeechHangover, isTrue);

      // 2. 紧随其后的微弱辅音帧受 600ms hangover 保护，依然放大 10 倍以上
      final conditionedConsonant =
          GeminiLivePcm.conditionLiveSamples(consonantFrame);
      expect(conditionedConsonant, isNot(same(consonantFrame)));
      double maxAmp = 0.0;
      for (final s in conditionedConsonant) {
        if (s.abs() > maxAmp) maxAmp = s.abs();
      }
      expect(maxAmp / 0.00035, greaterThan(10.0));
    });

    test('空闲底噪在未激活状态下保持 1.0x 原样透传不放大', () {
      final idleNoise = Float32List(1600);
      for (var i = 0; i < idleNoise.length; i++) {
        idleNoise[i] =
            (0.0003 * math.sin(2 * math.pi * 200 * i / 16000)).toDouble();
      }
      final outIdle = GeminiLivePcm.conditionLiveSamples(idleNoise);
      expect(outIdle, same(idleNoise));

      final playingNoise = Float32List(1600);
      for (var i = 0; i < playingNoise.length; i++) {
        playingNoise[i] =
            (0.0005 * math.sin(2 * math.pi * 200 * i / 16000)).toDouble();
      }
      final outPlaying = GeminiLivePcm.conditionLiveSamples(
        playingNoise,
        isPlayingOutput: true,
      );
      expect(outPlaying, same(playingNoise));
    });

    test('正常响度人声（0.25 振幅，rms > 0.085）保持原样透传', () {
      final loudSpeech = Float32List(1600);
      for (var i = 0; i < loudSpeech.length; i++) {
        loudSpeech[i] =
            (0.25 * math.sin(2 * math.pi * 300 * i / 16000)).toDouble();
      }
      final conditioned = GeminiLivePcm.conditionLiveSamples(loudSpeech);
      expect(conditioned, same(loudSpeech));
    });

    test('回声门限：在播放回声窗内，低振幅回声（0.0008 振幅，rms ~0.00056）静音输出且不触发打断', () {
      var bargeInTriggered = false;
      final echoSamples = Float32List(1600);
      for (var i = 0; i < echoSamples.length; i++) {
        echoSamples[i] =
            (0.0008 * math.sin(2 * math.pi * 1000 * i / 16000)).toDouble();
      }

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
      var bargeInTriggered = false;
      final speechSamples = Float32List(3200);
      for (var i = 0; i < speechSamples.length; i++) {
        final t = 2 * math.pi * 200 * i / 16000;
        speechSamples[i] =
            (0.006 * math.sin(t) + 0.003 * math.sin(2 * t)).toDouble();
      }

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
    test('Gemini Live 模式下免唤醒词、双向字幕实时上屏、服务端打断瞬时响应', () async {
      final fakeLive = _FakeGeminiLiveSession();
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final engine = AssistantEngine(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveVoice: 'Aoede',
        ),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
        'DialogueIntentCoordinator.previewVoice 分流路由：Gemini Live 音色走 Live 会话，标准音色走 TtsPort',
        () async {
      final fakeLive = _FakeGeminiLiveSession();
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final fakeTts = _FakeTtsPort();
      final engine = AssistantEngine(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeCascade,
          geminiApiKey: 'test-key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveVoice: 'Aoede',
          edgeVoice: 'zh-CN-XiaoxiaoNeural',
        ),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final engine = AssistantEngine(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveVoice: 'Aoede',
        ),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final engine = AssistantEngine(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test-key',
        ),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final engine = AssistantEngine(
        settings: AppSettings(
            pipelineMode: AppConstants.pipelineModeGeminiLive,
            geminiApiKey: 'k'),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
      GeminiLiveSessionFactoryRegistry.defaultFactory = (_) => fakeLive;
      addTearDown(() => GeminiLiveSessionFactoryRegistry.defaultFactory = null);

      final engine = AssistantEngine(
        settings: AppSettings(
            pipelineMode: AppConstants.pipelineModeGeminiLive,
            geminiApiKey: 'k'),
        enableDriverServer: false,
      );
      addTearDown(() => engine.dispose());

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
  });
}
