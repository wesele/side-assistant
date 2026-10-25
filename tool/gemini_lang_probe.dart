// Gemini 3.5 Transcribe Live 语言行为探针（一次性排查工具）。
// ignore_for_file: avoid_print
//
// 用途：对比 `inputAudioTranscription` 的不同配置下，模型对同一段音频给出的
// 文本和 languageCode，用来判断“中文被识别成西语/韩文”是模型自动语种检测的
// 正常行为，还是集成层没把语言提示传对。
//
// 运行：
//   dart run tool/gemini_lang_probe.dart
//   dart run tool/gemini_lang_probe.dart --configs=empty,hint
//   dart run tool/gemini_lang_probe.dart --wav=assets/models/sense-voice/test_wavs/ko.wav

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:side_assistant/core/constants/app_constants.dart';

const _wsUrl = AppConstants.geminiLiveWsUrl;
const _model = AppConstants.defaultGeminiAsrModel;

/// 只保留 BCP-47 里表示中文的标签。
bool _isChineseTag(String? tag) {
  if (tag == null) return false;
  final t = tag.toLowerCase();
  return t == 'zh' ||
      t.startsWith('zh-') ||
      t == 'cmn' ||
      t.startsWith('cmn-') ||
      t == 'yue' ||
      t.startsWith('yue-');
}

class _Wav {
  _Wav(this.sampleRate, this.channels, this.samples);

  final int sampleRate;
  final int channels;
  final Float32List samples;

  double get seconds => samples.length / sampleRate;
}

_Wav _readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('不是 WAV 文件: $path');
  }
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  var sampleRate = 16000;
  var channels = 1;
  var bits = 16;
  int? dataOffset;
  int? dataLength;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = math.min(size, bytes.length - body);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset == null || dataLength == null) {
    throw FormatException('WAV 缺少 data 块: $path');
  }
  if (bits != 16) throw FormatException('只支持 16-bit PCM，实际 $bits');
  final frames = dataLength ~/ (2 * channels);
  final samples = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    // 多声道取第一声道，够用。
    samples[i] = data.getInt16(dataOffset + i * 2 * channels, Endian.little) /
        32768.0;
  }
  return _Wav(sampleRate, channels, samples);
}

Float32List _resample(Float32List input, int from, int to) {
  if (from == to) return input;
  final outLength = (input.length * to / from).round();
  final output = Float32List(outLength);
  final ratio = from / to;
  for (var i = 0; i < outLength; i++) {
    final position = i * ratio;
    final index = position.floor();
    final next = math.min(index + 1, input.length - 1);
    final fraction = position - index;
    output[i] = input[index] * (1 - fraction) + input[next] * fraction;
  }
  return output;
}

Uint8List _toPcm16(Float32List samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0).toDouble();
    data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return bytes;
}

class ProbeResult {
  ProbeResult(this.label);

  final String label;
  final List<String> finals = <String>[];
  final List<String> interims = <String>[];
  final List<String> languageCodes = <String>[];
  final List<String> activities = <String>[];
  String? error;
  bool gotTurnComplete = false;
  bool gotGenerationComplete = false;
  bool setupOk = false;
}

Future<ProbeResult> _run(
  String label,
  Map<String, dynamic> transcriptionConfig,
  Float32List samples16k,
) async {
  final result = ProbeResult(label);
  final uri = Uri.parse(
    '$_wsUrl?key=${Uri.encodeQueryComponent(AppConstants.defaultGeminiApiKey)}',
  );
  final socket = await WebSocket.connect(uri.toString())
      .timeout(const Duration(seconds: 20));
  final done = Completer<void>();
  Timer? silenceTimer;

  void finish() {
    if (!done.isCompleted) done.complete();
  }

  socket.listen((raw) {
    final text = raw is String ? raw : utf8.decode(raw as List<int>);
    Map<String, dynamic> message;
    try {
      message = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (message.containsKey('setupComplete')) {
      result.setupOk = true;
      return;
    }
    if (message['error'] != null) {
      result.error = jsonEncode(message['error']);
      finish();
      return;
    }
    final voiceActivity = message['voiceActivity'];
    if (voiceActivity is Map) {
      result.activities.add('${voiceActivity['type']}@${voiceActivity['audioOffset']}');
    }
    final serverContent = message['serverContent'];
    if (serverContent is Map) {
      final interim = serverContent['interimInputTranscription'];
      if (interim is Map && interim['text'] is String) {
        result.interims.add(interim['text'] as String);
        final code = interim['languageCode'];
        if (code is String) result.languageCodes.add('interim:$code');
      }
      final finalTranscription = serverContent['inputTranscription'];
      if (finalTranscription is Map && finalTranscription['text'] is String) {
        result.finals.add(finalTranscription['text'] as String);
        final code = finalTranscription['languageCode'];
        if (code is String) result.languageCodes.add('final:$code');
      }
      if (serverContent['generationComplete'] == true) {
        result.gotGenerationComplete = true;
      }
      if (serverContent['turnComplete'] == true) {
        result.gotTurnComplete = true;
        finish();
        return;
      }
    }
    silenceTimer?.cancel();
    silenceTimer = Timer(const Duration(seconds: 4), finish);
  }, onError: (Object e) {
    result.error = e.toString();
    finish();
  }, onDone: finish);

  socket.add(jsonEncode({
    'setup': {
      'model': 'models/$_model',
      'generationConfig': {
        'responseModalities': ['TEXT'],
      },
      'inputAudioTranscription': transcriptionConfig,
    },
  }));

  // 等 setupComplete，最多 15s。
  final setupDeadline = DateTime.now().add(const Duration(seconds: 15));
  while (!result.setupOk && result.error == null && DateTime.now().isBefore(setupDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!result.setupOk) {
    result.error ??= 'setup 超时/失败';
    await socket.close();
    return result;
  }

  final pcm = _toPcm16(samples16k);
  const chunk = 1600 * 2;
  for (var offset = 0; offset < pcm.length; offset += chunk) {
    final end = math.min(offset + chunk, pcm.length);
    socket.add(jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
        },
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  socket.add(jsonEncode({
    'realtimeInput': {'audioStreamEnd': true},
  }));

  try {
    await done.future.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    result.error ??= '收尾超时';
  }
  silenceTimer?.cancel();
  await socket.close();
  return result;
}

String _quote(String s) => s.isEmpty ? '""' : '"$s"';

/// 生成“非语音”片段，验证模型在静音/底噪上是否会产生外语幻觉。
List<(String, Float32List)> _syntheticClips(Float32List zh) {
  final random = math.Random(7);
  Float32List noise(double amplitude, double seconds) {
    final out = Float32List((16000 * seconds).round());
    for (var i = 0; i < out.length; i++) {
      out[i] = (random.nextDouble() * 2 - 1) * amplitude;
    }
    return out;
  }

  final short = Float32List.fromList(zh.sublist(0, math.min(zh.length, 16000)));
  final quiet = Float32List(zh.length);
  for (var i = 0; i < zh.length; i++) {
    quiet[i] = zh[i] * 0.03;
  }
  return <(String, Float32List)>[
    ('silence-1s', Float32List(16000)),
    ('noise-40dB-1s', noise(0.01, 1.0)),
    ('noise-30dB-1s', noise(0.03, 1.0)),
    ('zh-first-1s', short),
    ('zh-quiet-x0.03', quiet),
  ];
}

Future<void> main(List<String> args) async {
  final synthMode = args.contains('--synth');
  final wavArg = args.firstWhere((a) => a.startsWith('--wavs='), orElse: () => '');
  final wavPaths = wavArg.isEmpty
      ? <String>[
          'assets/models/sense-voice/test_wavs/zh.wav',
          'assets/models/sense-voice/test_wavs/ko.wav',
        ]
      : wavArg
          .substring('--wavs='.length)
          .split(',')
          .map((name) => name.contains('/')
              ? name
              : 'assets/models/sense-voice/test_wavs/$name')
          .toList();
  final configArg = args.firstWhere((a) => a.startsWith('--configs='), orElse: () => '');
  final configs = <String, Map<String, dynamic>>{
    // 与当前集成完全一致：空配置 => 自动语种检测。
    'empty': <String, dynamic>{},
    // 官方文档里的写法：languageCodes 放在 inputAudioTranscription 里面。
    'hint-zh': <String, dynamic>{
      'languageCodes': ['cmn-Hans-CN'],
    },
    // 故意给错的提示，用来确认字段确实生效（而不是被忽略）。
    'hint-ko': <String, dynamic>{
      'languageCodes': ['ko-KR'],
    },
  };

  final selected = configArg.isEmpty
      ? <String>['empty', 'hint-zh', 'hint-ko']
      : configArg.substring('--configs='.length).split(',');

  if (synthMode) {
    final zh = _resample(
      _readWav('assets/models/sense-voice/test_wavs/zh.wav').samples,
      16000,
      16000,
    );
    for (final clip in _syntheticClips(zh)) {
      final result = await _run('empty', <String, dynamic>{}, clip.$2);
      print('\n--- ${clip.$1} (${(clip.$2.length / 16000).toStringAsFixed(2)}s)');
      print('    setup=${result.setupOk} gen=${result.gotGenerationComplete} '
          'turn=${result.gotTurnComplete} error=${result.error ?? '-'}');
      print('    langTags=${result.languageCodes.toSet()}');
      print('    final=${result.finals.map(_quote).join(' | ')}');
      print('    interim(last)=${_quote(result.interims.isEmpty ? '' : result.interims.last)}');
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return;
  }

  for (final path in wavPaths) {
    final wav = _readWav(path);
    final samples = _resample(wav.samples, wav.sampleRate, 16000);
    print('\n=== ${path.split('/').last} '
        '(${wav.sampleRate}Hz ${wav.channels}ch, ${wav.seconds.toStringAsFixed(2)}s) ===');
    for (final name in selected) {
      final config = configs[name]!;
      final result = await _run(name, config, samples);
      print('--- $name ${jsonEncode(config)}');
      print('    setup=${result.setupOk} gen=${result.gotGenerationComplete} '
          'turn=${result.gotTurnComplete} error=${result.error ?? '-'}');
      print('    langTags=${result.languageCodes.toSet()}');
      print('    final=${result.finals.map(_quote).join(' | ')}');
      print('    interim(last)=${_quote(result.interims.isEmpty ? '' : result.interims.last)}');
      if (result.finals.isNotEmpty) {
        final tag = result.languageCodes
            .where((c) => c.startsWith('final:'))
            .map((c) => c.substring(6))
            .toList();
        final anyChinese = tag.any(_isChineseTag);
        print('    detectedZh=$anyChinese');
      }
      // 避免触发限流。
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }
}
