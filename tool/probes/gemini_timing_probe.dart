// Gemini 3.5 Transcribe Live 时延探针：把一次识别的耗时拆成
// “上传 / 模型出字 / 收尾等待”几段，用来判断现有集成在速度上还有多少水分。
// ignore_for_file: avoid_print
//
// 用法：
//   dart run tool/probes/gemini_timing_probe.dart                       # 10x 上传（现状）
//   dart run tool/probes/gemini_timing_probe.dart --pace=100            # 1x 实时上传
//   dart run tool/probes/gemini_timing_probe.dart --pace=2              # 50x 上传
//   dart run tool/probes/gemini_timing_probe.dart --wav=... --pace=10

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:side_assistant/core/constants/app_constants.dart';

const _wsUrl = AppConstants.geminiLiveWsUrl;
const _model = AppConstants.defaultGeminiAsrModel;

class _Wav {
  _Wav(this.sampleRate, this.channels, this.samples);

  final int sampleRate;
  final int channels;
  final Float32List samples;
}

_Wav _readWav(String path) {
  final bytes = File(path).readAsBytesSync();
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
    samples[i] =
        data.getInt16(dataOffset + i * 2 * channels, Endian.little) / 32768.0;
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

class _Timing {
  int? setupMs;
  int? uploadMs;
  final List<String> events = <String>[];
  final List<String> activities = <String>[];
  String finalText = '';
  String? error;
  bool gotFinal = false;
  bool gotGenComplete = false;
  bool gotTurnComplete = false;

  void at(String label, int msSinceAudioEnd) =>
      events.add('$label@${msSinceAudioEnd}ms');
}

Future<_Timing> _run(Float32List samples16k, int paceMs, int batch) async {
  final t = _Timing();
  final connectStart = DateTime.now();
  final socket = await WebSocket.connect(
    Uri.parse(
      '$_wsUrl?key=${Uri.encodeQueryComponent(AppConstants.defaultGeminiApiKey)}',
    ).toString(),
  ).timeout(const Duration(seconds: 20));
  final done = Completer<void>();
  Timer? silence;
  final audioEndAt = <int>[0]; // 毫秒时间戳，发送 audioStreamEnd 时写入
  var ended = false;

  int sinceEnd() => ended
      ? DateTime.now()
          .difference(audioEndAt[0] == 0
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(audioEndAt[0]))
          .inMilliseconds
      : 0;

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
      t.setupMs = DateTime.now().difference(connectStart).inMilliseconds;
      return;
    }
    if (message['error'] != null) {
      t.error = jsonEncode(message['error']);
      finish();
      return;
    }
    final voiceActivity = message['voiceActivity'];
    if (voiceActivity is Map) {
      t.activities
          .add('${voiceActivity['type']}@${voiceActivity['audioOffset']}');
      t.at('${voiceActivity['type']}', sinceEnd());
    }
    final serverContent = message['serverContent'];
    if (serverContent is Map) {
      final interim = serverContent['interimInputTranscription'];
      if (interim is Map && interim['text'] is String) {
        t.at('interim', sinceEnd());
      }
      final finalTranscription = serverContent['inputTranscription'];
      if (finalTranscription is Map && finalTranscription['text'] is String) {
        t.finalText = finalTranscription['text'] as String;
        t.gotFinal = true;
        t.at('final', sinceEnd());
      }
      if (serverContent['generationComplete'] == true) {
        t.gotGenComplete = true;
        t.at('generationComplete', sinceEnd());
      }
      if (serverContent['turnComplete'] == true) {
        t.gotTurnComplete = true;
        t.at('turnComplete', sinceEnd());
        finish();
        return;
      }
    }
    silence?.cancel();
    silence = Timer(const Duration(seconds: 4), finish);
  }, onError: (Object e) {
    t.error = e.toString();
    finish();
  }, onDone: finish);

  socket.add(jsonEncode({
    'setup': {
      'model': 'models/$_model',
      'generationConfig': {
        'responseModalities': ['TEXT'],
      },
      'inputAudioTranscription': {
        'languageCodes': [AppConstants.geminiAsrLanguageCode],
      },
    },
  }));

  final setupDeadline = DateTime.now().add(const Duration(seconds: 15));
  while (t.setupMs == null &&
      t.error == null &&
      DateTime.now().isBefore(setupDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (t.setupMs == null) {
    t.error ??= 'setup 超时';
    await socket.close();
    return t;
  }

  final pcm = _toPcm16(samples16k);
  const chunk = 1600 * 2;
  final uploadStart = DateTime.now();
  var inBatch = 0;
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
    inBatch++;
    if (inBatch >= batch) {
      inBatch = 0;
      if (paceMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: paceMs));
      }
    }
  }
  ended = true;
  audioEndAt[0] = DateTime.now().millisecondsSinceEpoch;
  t.uploadMs = audioEndAt[0] - uploadStart.millisecondsSinceEpoch;
  socket.add(jsonEncode({
    'realtimeInput': {'audioStreamEnd': true},
  }));

  try {
    await done.future.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    t.error ??= '收尾超时';
  }
  silence?.cancel();
  await socket.close();
  return t;
}

void _report(String wav, int paceMs, int batch, _Timing t) {
  final speed = paceMs == 0 ? 0.0 : (100.0 * batch / paceMs);
  final paceLabel = paceMs == 0
      ? 'burst'
      : '${speed.toStringAsFixed(1)}x (${paceMs}ms×$batch)';
  print('\n=== $wav  pace=$paceLabel');
  print('    setup=${t.setupMs}ms upload=${t.uploadMs}ms '
      'error=${t.error ?? '-'}');
  print('    activities=${t.activities}');
  print('    events=${t.events}');
  print('    final="${t.finalText}"');
  final gen = t.events
      .where((e) => e.startsWith('generationComplete@'))
      .map((e) => int.parse(e.split('@')[1].replaceAll('ms', '')))
      .firstOrNull;
  if (gen != null) {
    // 现有实现：没有 turnComplete 时，generationComplete 后还要再等 250ms。
    print('    现有收尾：generationComplete + 250ms = ${gen + 250}ms'
        '（若走 1200ms 兜底则 ${gen + 1200}ms）');
  }
}

Future<void> main(List<String> args) async {
  final wavArg =
      args.firstWhere((a) => a.startsWith('--wav='), orElse: () => '');
  final wav = wavArg.isEmpty
      ? 'assets/models/sense-voice/test_wavs/zh.wav'
      : wavArg.substring('--wav='.length);
  final paceArg =
      args.firstWhere((a) => a.startsWith('--pace='), orElse: () => '');
  final paces = paceArg.isEmpty
      ? <int>[10]
      : paceArg.substring('--pace='.length).split(',').map(int.parse).toList();
  final batchArg =
      args.firstWhere((a) => a.startsWith('--batch='), orElse: () => '');
  final batch =
      batchArg.isEmpty ? 1 : int.parse(batchArg.substring('--batch='.length));

  final file = _readWav(wav);
  final samples = _resample(file.samples, file.sampleRate, 16000);
  print('音频 ${(samples.length / 16000).toStringAsFixed(2)}s '
      '(${file.sampleRate}Hz ${file.channels}ch)');

  for (final pace in paces) {
    final t = await _run(samples, pace, batch);
    _report(wav.split('/').last, pace, batch, t);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}
