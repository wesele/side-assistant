// Gemini Live 稳定性探针：复刻 App 里两条真实识别路径，量化移动端出现的问题。
// ignore_for_file: avoid_print
//
// 用法：
//   dart run tool/gemini_stability_probe.dart --mode=segment --turns=5
//   dart run tool/gemini_stability_probe.dart --mode=live --turns=5
//   dart run tool/gemini_stability_probe.dart --idle=90
//   dart run tool/gemini_stability_probe.dart --reconnect=5
//
// 关注点：
//   - 连续多轮复用同一条连接时，第 2/3 轮是否还能拿到 generationComplete；
//   - live（边说边传，1x 实时上传）与 segment（整段 10x 上传）的收尾差异；
//   - 空闲多久被服务端关闭；
//   - 重连（connect + setup）耗时。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:side_assistant/core/constants/app_constants.dart';

const _wsUrl = AppConstants.geminiLiveWsUrl;
const _model = AppConstants.defaultGeminiAsrModel;
const _apiKey = AppConstants.defaultGeminiApiKey;

// ---------------------------------------------------------------------------
// WAV
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// 会话
// ---------------------------------------------------------------------------

class TurnResult {
  TurnResult(this.mode);

  final String mode;
  int uploadMs = 0;
  int? firstInterimMs;
  int? finalMs;
  int? genCompleteMs;
  int? turnCompleteMs;
  int totalMs = 0;
  String text = '';
  String? error;
  bool get gotGenComplete => genCompleteMs != null;
  bool get gotTurnComplete => turnCompleteMs != null;
  bool get gotFinal => finalMs != null;
}

class Session {
  Session(this.socket);

  final WebSocket socket;
  int? setupMs;
  bool alive = true;
  String? closeReason;
  final List<String> serverErrors = <String>[];

  // 当前轮状态
  TurnResult? _turn;
  int _audioEndAt = 0;
  bool _audioEnded = false;
  Completer<void>? _turnDone;
  Timer? _silence;

  int _sinceEnd() => _audioEndAt == 0
      ? 0
      : DateTime.now().millisecondsSinceEpoch - _audioEndAt;

  void _handle(dynamic raw) {
    final text = raw is String ? raw : utf8.decode(raw as List<int>);
    Map<String, dynamic> message;
    try {
      message = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (message.containsKey('setupComplete')) return;

    final error = message['error'];
    if (error != null) {
      final msg = error is Map ? (error['message']?.toString() ?? '$error') : '$error';
      serverErrors.add(msg);
      _turn?.error ??= msg;
      _turnDone?.complete();
      return;
    }

    final goAway = message['goAway'];
    if (goAway != null) {
      closeReason = 'goAway: $goAway';
    }

    final turn = _turn;
    if (turn != null) {
      final serverContent = message['serverContent'];
      if (serverContent is Map) {
        final interim = serverContent['interimInputTranscription'];
        if (interim is Map && interim['text'] is String) {
          turn.firstInterimMs ??= _sinceEnd();
        }
        final finalTranscription = serverContent['inputTranscription'];
        if (finalTranscription is Map && finalTranscription['text'] is String) {
          final t = finalTranscription['text'] as String;
          if (t.isNotEmpty) {
            turn.text = t;
            turn.finalMs ??= _sinceEnd();
          }
        }
        if (serverContent['generationComplete'] == true) {
          turn.genCompleteMs ??= _sinceEnd();
        }
        if (serverContent['turnComplete'] == true) {
          turn.turnCompleteMs ??= _sinceEnd();
          _turnDone?.complete();
          return;
        }
      }
      // 静默兜底：4s 没有任何消息就收尾（与线上 _armHardFinishTimer 一致）。
      if (_audioEnded) {
        _silence?.cancel();
        _silence = Timer(const Duration(seconds: 4), () {
          _turnDone?.complete();
        });
      }
    }
  }

  static Future<Session> connect({int timeoutSeconds = 20}) async {
    final connecting = WebSocket.connect(
      Uri.parse('$_wsUrl?key=${Uri.encodeQueryComponent(_apiKey)}').toString(),
    );
    final socket = await connecting.timeout(Duration(seconds: timeoutSeconds));
    final session = Session(socket);
    final setupDone = Completer<void>();
    socket.listen(
      (raw) {
        final text = raw is String ? raw : utf8.decode(raw as List<int>);
        Map<String, dynamic>? message;
        try {
          message = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
        if (message != null && message.containsKey('setupComplete')) {
          if (!setupDone.isCompleted) setupDone.complete();
        }
        session._handle(raw);
      },
      onError: (Object e) {
        session.alive = false;
        session.closeReason = 'error: $e';
        if (!setupDone.isCompleted) setupDone.complete();
        session._turnDone?.complete();
      },
      onDone: () {
        session.alive = false;
        session.closeReason ??= 'server closed';
        if (!setupDone.isCompleted) setupDone.complete();
        session._turnDone?.complete();
      },
    );
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
    await setupDone.future.timeout(Duration(seconds: timeoutSeconds));
    return session;
  }

  /// 整段存储转发：10ms 一批 100ms 音频（与 GeminiLiveAsrService._transcribeNormalized 一致）。
  Future<TurnResult> runSegment(Float32List samples16k, {int paceMs = 10}) async {
    final turn = TurnResult('segment');
    return _run(turn, () async {
      final pcm = _toPcm16(samples16k);
      const chunk = 1600 * 2;
      final sw = Stopwatch()..start();
      for (var offset = 0; offset < pcm.length; offset += chunk) {
        if (!alive) throw StateError('socket closed: $closeReason');
        final end = math.min(offset + chunk, pcm.length);
        socket.add(jsonEncode({
          'realtimeInput': {
            'audio': {
              'mimeType': 'audio/pcm;rate=16000',
              'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
            },
          },
        }));
        await Future<void>.delayed(Duration(milliseconds: paceMs));
      }
      sw.stop();
      turn.uploadMs = sw.elapsedMilliseconds;
    });
  }

  /// 边说边传：按 1x 实时上传（与 VoiceListeningService._pumpLiveAudio 一致）。
  Future<TurnResult> runLive(Float32List samples16k) async {
    final turn = TurnResult('live');
    return _run(turn, () async {
      final pcm = _toPcm16(samples16k);
      const chunk = 1600 * 2; // 100ms
      final sw = Stopwatch()..start();
      var chunkIndex = 0;
      for (var offset = 0; offset < pcm.length; offset += chunk) {
        if (!alive) throw StateError('socket closed: $closeReason');
        final end = math.min(offset + chunk, pcm.length);
        socket.add(jsonEncode({
          'realtimeInput': {
            'audio': {
              'mimeType': 'audio/pcm;rate=16000',
              'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
            },
          },
        }));
        chunkIndex++;
        // 1x 实时：每 100ms 音频等 100ms。
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      sw.stop();
      turn.uploadMs = sw.elapsedMilliseconds;
      print('    (live 上传完成，用时 ${turn.uploadMs}ms, $chunkIndex 块)');
    });
  }

  Future<TurnResult> _run(TurnResult turn, Future<void> Function() upload) async {
    _turn = turn;
    _audioEnded = false;
    _audioEndAt = 0;
    _turnDone = Completer<void>();
    final sw = Stopwatch()..start();
    try {
      await upload();
      _audioEndAt = DateTime.now().millisecondsSinceEpoch;
      _audioEnded = true;
      socket.add(jsonEncode({
        'realtimeInput': {'audioStreamEnd': true},
      }));
      await _turnDone!.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      turn.error ??= '收尾超时(20s)';
    } catch (e) {
      turn.error ??= '$e';
    }
    sw.stop();
    turn.totalMs = sw.elapsedMilliseconds;
    _silence?.cancel();
    _silence = null;
    _turn = null;
    _turnDone = null;
    return turn;
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

String _fmt(TurnResult t) {
  String ms(int? v) => v == null ? '—' : '${v}ms';
  final conf = [
    'upload=${t.uploadMs}ms',
    'interim=${ms(t.firstInterimMs)}',
    'final=${ms(t.finalMs)}',
    'genComplete=${ms(t.genCompleteMs)}',
    'turnComplete=${ms(t.turnCompleteMs)}',
    'total=${t.totalMs}ms',
  ].join('  ');
  return '[${t.mode}] $conf\n            text="${t.text}"'
      '${t.error != null ? '  error=${t.error}' : ''}';
}

Future<void> _runTurns(String mode, int turns, int gapMs, Float32List audio) async {
  print('\n=== 连续 $turns 轮 / mode=$mode / 轮间间隔 ${gapMs}ms ===');
  final sw = Stopwatch()..start();
  final session = await Session.connect();
  print('连接+setup 用时 ${sw.elapsedMilliseconds}ms');
  try {
    for (var i = 1; i <= turns; i++) {
      if (!session.alive) {
        print('轮 $i: 连接已断开 (${session.closeReason})，按线上逻辑将重连');
        final reconnect = Stopwatch()..start();
        final next = await Session.connect();
        print('    重连用时 ${reconnect.elapsedMilliseconds}ms');
        await session.close();
        // 让局部变量切换到新 session 不可行（final），这里简单直接返回。
        next.close();
        return;
      }
      final t = mode == 'live'
          ? await session.runLive(audio)
          : await session.runSegment(audio);
      print('轮 $i: ${_fmt(t)}');
      if (session.serverErrors.isNotEmpty) {
        print('    服务端错误: ${session.serverErrors.last}');
        session.serverErrors.clear();
      }
      if (i < turns) {
        await Future<void>.delayed(Duration(milliseconds: gapMs));
      }
    }
  } finally {
    await session.close();
  }
}

Future<void> _runIdleProbe(int seconds) async {
  print('\n=== 空闲断连探针 (保持连接 $seconds s，不发音频) ===');
  final session = await Session.connect();
  print('连接+setup 完成，开始计时（每 5s 打点）');
  final sw = Stopwatch()..start();
  while (sw.elapsed.inSeconds < seconds && session.alive) {
    await Future<void>.delayed(const Duration(seconds: 5));
    print('  t=${sw.elapsed.inSeconds}s alive=${session.alive} '
        '${session.closeReason ?? ''}');
  }
  print(
    session.alive
        ? '  ${seconds}s 内未被关闭'
        : '  → 空闲 ${sw.elapsed.inSeconds}s 被服务端关闭 (${session.closeReason})',
  );
  await session.close();
}

Future<void> _runReconnectProbe(int times) async {
  print('\n=== 重连耗时探针 (连续建连 $times 次) ===');
  final durations = <int>[];
  for (var i = 1; i <= times; i++) {
    final sw = Stopwatch()..start();
    try {
      final s = await Session.connect();
      sw.stop();
      durations.add(sw.elapsedMilliseconds);
      print('  第 $i 次: ${sw.elapsedMilliseconds}ms');
      await s.close();
    } catch (e) {
      print('  第 $i 次失败: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (durations.isNotEmpty) {
    final avg = durations.reduce((a, b) => a + b) / durations.length;
    print('  平均 ${avg.toStringAsFixed(0)}ms  最大 ${durations.reduce(math.max)}ms');
  }
}

Future<void> main(List<String> args) async {
  String argOf(String name, String def) {
    final hit = args.firstWhere((a) => a.startsWith('--$name='), orElse: () => '');
    return hit.isEmpty ? def : hit.substring('--$name='.length);
  }

  final mode = argOf('mode', 'segment');
  final turns = int.parse(argOf('turns', '3'));
  final gapMs = int.parse(argOf('gap', '1200'));
  final idle = int.parse(argOf('idle', '0'));
  final reconnect = int.parse(argOf('reconnect', '0'));
  final wav = argOf('wav', 'assets/models/sense-voice/test_wavs/zh.wav');

  final file = _readWav(wav);
  final audio = _resample(file.samples, file.sampleRate, 16000);
  print('音频 ${wav.split('/').last} '
      '${(audio.length / 16000).toStringAsFixed(2)}s @16k');

  if (turns > 0) await _runTurns(mode, turns, gapMs, audio);
  if (idle > 0) await _runIdleProbe(idle);
  if (reconnect > 0) await _runReconnectProbe(reconnect);
}
