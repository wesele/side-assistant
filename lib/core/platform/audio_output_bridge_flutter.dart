import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/app_settings.dart';
import 'audio_output_bridge_io.dart' as io_impl;

class PlatformSoundPlayer {
  String outputDeviceId;
  AudioPlayer? _player;
  io_impl.PlatformSoundPlayer? _linuxPlayer;

  PlatformSoundPlayer({this.outputDeviceId = ''}) {
    if (Platform.isLinux) {
      _linuxPlayer = io_impl.PlatformSoundPlayer(outputDeviceId: outputDeviceId);
    }
  }

  Future<void> playWavBytes(Uint8List wav, {String tag = 'tone'}) async {
    if (Platform.isLinux) {
      _linuxPlayer!.outputDeviceId = outputDeviceId;
      await _linuxPlayer!.playWavBytes(wav, tag: tag);
      return;
    }
    try {
      unawaited(SystemSound.play(SystemSoundType.click));
    } catch (_) {}

    try {
      _player ??= AudioPlayer();
      await _player!.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (_) {}
  }

  void dispose() {
    _linuxPlayer?.dispose();
    try {
      _player?.dispose();
    } catch (_) {}
  }
}

class PlatformTtsBackend {
  final AppSettings settings;
  FlutterTts? _flutterTts;
  AudioPlayer? _audioPlayer;
  StreamSubscription? _playerCompleteSub;
  Completer<void>? _audioPlayerCompleter;
  Completer<void>? _systemSpeakCompleter;
  io_impl.PlatformTtsBackend? _linuxBackend;

  PlatformTtsBackend({required this.settings}) {
    if (Platform.isLinux) {
      _linuxBackend = io_impl.PlatformTtsBackend(settings: settings);
    }
  }

  Future<void> init() async {
    if (Platform.isLinux) {
      await _linuxBackend!.init();
      return;
    }
    try {
      _flutterTts ??= FlutterTts();
      final tts = _flutterTts!;
      if (Platform.isAndroid) {
        try {
          final engines = await tts.getEngines;
          debugPrint('[TtsService] Android 检测到可用 TTS 引擎: $engines');
          final defaultEngine = await tts.getDefaultEngine;
          debugPrint('[TtsService] Android 系统默认 TTS 引擎: $defaultEngine');

          if (engines is List && engines.isNotEmpty) {
            if (defaultEngine == null || !engines.contains(defaultEngine)) {
              final chosen = engines.firstWhere(
                (e) =>
                    e == 'com.google.android.tts' ||
                    e.toString().contains('google'),
                orElse: () => engines.first,
              );
              await tts.setEngine(chosen.toString());
              debugPrint('[TtsService] 已将 TTS 引擎指定为: $chosen');
            }
          }
        } catch (e) {
          debugPrint('[TtsService] 获取/设置 Android TTS 引擎异常: $e');
        }
      }

      final langRes = await tts.setLanguage('zh-CN');
      if (langRes == 0) {
        await tts.setLanguage('zh');
      }
      await tts.setSpeechRate(settings.ttsSpeed * 0.5);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);

      tts.setCompletionHandler(() {
        if (_systemSpeakCompleter != null &&
            !_systemSpeakCompleter!.isCompleted) {
          _systemSpeakCompleter!.complete();
        }
      });

      tts.setCancelHandler(() {
        if (_systemSpeakCompleter != null &&
            !_systemSpeakCompleter!.isCompleted) {
          _systemSpeakCompleter!.complete();
        }
      });

      tts.setErrorHandler((msg) {
        debugPrint('[TtsService] flutter_tts 错误: $msg');
        if (_systemSpeakCompleter != null &&
            !_systemSpeakCompleter!.isCompleted) {
          _systemSpeakCompleter!.complete();
        }
      });
    } catch (e) {
      debugPrint('[TtsService] 初始化 TTS 异常: $e');
    }
  }

  Future<void> playAudioFile(String filePath, {Duration? timeout}) async {
    if (Platform.isLinux) {
      await _linuxBackend!.playAudioFile(filePath, timeout: timeout);
      return;
    }
    _audioPlayer ??= AudioPlayer();
    _audioPlayerCompleter = Completer<void>();
    _playerCompleteSub?.cancel();
    _playerCompleteSub = _audioPlayer!.onPlayerComplete.listen((_) {
      if (_audioPlayerCompleter != null &&
          !_audioPlayerCompleter!.isCompleted) {
        _audioPlayerCompleter!.complete();
      }
    });

    await _audioPlayer!.play(DeviceFileSource(filePath));
    if (timeout != null) {
      await _audioPlayerCompleter!.future.timeout(timeout, onTimeout: () {});
    } else {
      await _audioPlayerCompleter!.future;
    }
  }

  Future<void> speakSystemTts(String sentence, {Duration? timeout}) async {
    if (Platform.isLinux) {
      await _linuxBackend!.speakSystemTts(sentence, timeout: timeout);
      return;
    }
    final tts = _flutterTts;
    if (tts == null) return;
    _systemSpeakCompleter = Completer<void>();
    await tts.speak(sentence).timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        debugPrint('[TtsService] flutter_tts speak 调用超时');
        return 0;
      },
    );
    if (timeout != null) {
      await _systemSpeakCompleter!.future.timeout(timeout, onTimeout: () {});
    } else {
      await _systemSpeakCompleter!.future;
    }
  }

  Future<void> stop() async {
    if (Platform.isLinux) {
      await _linuxBackend!.stop();
      return;
    }
    try {
      if (_audioPlayer != null) {
        await _audioPlayer!.stop();
      }
      if (_audioPlayerCompleter != null &&
          !_audioPlayerCompleter!.isCompleted) {
        _audioPlayerCompleter!.complete();
      }
    } catch (_) {}

    try {
      await _flutterTts?.stop();
      if (_systemSpeakCompleter != null &&
          !_systemSpeakCompleter!.isCompleted) {
        _systemSpeakCompleter!.complete();
      }
    } catch (_) {}
  }

  void dispose() {
    _linuxBackend?.dispose();
    unawaited(stop());
    _playerCompleteSub?.cancel();
    _audioPlayer?.dispose();
  }
}
