import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../core/models/app_settings.dart';
import 'edge_tts_service.dart';

class TtsService {
  final AppSettings settings;
  late final FlutterTts _flutterTts;
  late final EdgeTtsService _edgeTtsService;
  AudioPlayer? _audioPlayer;
  StreamSubscription? _playerCompleteSub;
  Completer<void>? _audioPlayerCompleter;

  bool _isSpeaking = false;
  Completer<void>? _currentSpeakCompleter;

  final List<String> _sentenceQueue = [];
  bool _isQueueWorkerRunning = false;
  bool Function()? _currentShouldCancel;
  Completer<void>? _allFinishedCompleter;

  TtsService({required this.settings}) {
    _flutterTts = FlutterTts();
    _edgeTtsService = EdgeTtsService();
    _initTts();
  }

  bool get isEdgeTtsAvailable => _edgeTtsService.isAvailable;

  bool get isSpeaking => _isSpeaking || _sentenceQueue.isNotEmpty || _isQueueWorkerRunning;

  Future<void> _initTts() async {
    try {
      await _flutterTts.setLanguage('zh-CN');
      await _flutterTts.setSpeechRate(settings.ttsSpeed * 0.5); // flutter_tts 默认 0.5 正常语速
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      _flutterTts.setStartHandler(() {
        _isSpeaking = true;
      });

      _flutterTts.setCompletionHandler(() {
        _isSpeaking = false;
        if (_currentSpeakCompleter != null && !_currentSpeakCompleter!.isCompleted) {
          _currentSpeakCompleter!.complete();
        }
      });

      _flutterTts.setCancelHandler(() {
        _isSpeaking = false;
        if (_currentSpeakCompleter != null && !_currentSpeakCompleter!.isCompleted) {
          _currentSpeakCompleter!.complete();
        }
      });

      _flutterTts.setErrorHandler((msg) {
        _isSpeaking = false;
        if (_currentSpeakCompleter != null && !_currentSpeakCompleter!.isCompleted) {
          _currentSpeakCompleter!.complete();
        }
      });
    } catch (_) {}
  }

  /// 立即播放短控制语音（如“好的”、“已取消”），打断当前正在朗读的内容
  Future<void> speakImmediate(String text) async {
    if (!settings.enableTtsPlayback) return;
    await stop();
    await _speakSentence(text);
  }

  /// 停止播放（用于打断 Barge-in 或取消）
  Future<void> stop() async {
    _sentenceQueue.clear();
    _isQueueWorkerRunning = false;
    _edgeTtsService.cancelAll();

    try {
      if (_audioPlayer != null) {
        await _audioPlayer!.stop();
      }
      if (_audioPlayerCompleter != null && !_audioPlayerCompleter!.isCompleted) {
        _audioPlayerCompleter!.complete();
      }
    } catch (_) {}

    try {
      await _flutterTts.stop();
      _isSpeaking = false;
      if (_currentSpeakCompleter != null && !_currentSpeakCompleter!.isCompleted) {
        _currentSpeakCompleter!.complete();
      }
      if (_allFinishedCompleter != null && !_allFinishedCompleter!.isCompleted) {
        _allFinishedCompleter!.complete();
      }
    } catch (_) {}
  }

  /// 将流式切句追加进顺序队列，后台单任务依次朗读，避免多句并发踩踏
  void enqueueSentence(String sentence, {bool Function()? shouldCancel}) {
    if (!settings.enableTtsPlayback) return;
    final clean = sentence.trim();
    if (clean.isEmpty) return;

    _currentShouldCancel = shouldCancel;
    _sentenceQueue.add(clean);

    if (_allFinishedCompleter == null || _allFinishedCompleter!.isCompleted) {
      _allFinishedCompleter = Completer<void>();
    }

    if (!_isQueueWorkerRunning) {
      _startQueueWorker();
    }
  }

  Future<void> _startQueueWorker() async {
    _isQueueWorkerRunning = true;
    while (_sentenceQueue.isNotEmpty) {
      if (_currentShouldCancel != null && _currentShouldCancel!()) {
        _sentenceQueue.clear();
        break;
      }
      final sentence = _sentenceQueue.removeAt(0);
      await _speakSentence(sentence);
    }
    _isQueueWorkerRunning = false;
    if (_sentenceQueue.isEmpty && _allFinishedCompleter != null && !_allFinishedCompleter!.isCompleted) {
      _allFinishedCompleter!.complete();
    }
  }

  /// 等待当前所有排队的句子全部发音完成
  Future<void> waitForCompletion() async {
    if (!_isQueueWorkerRunning && _sentenceQueue.isEmpty) {
      return;
    }
    if (_allFinishedCompleter != null && !_allFinishedCompleter!.isCompleted) {
      await _allFinishedCompleter!.future;
    }
  }

  /// 顺序逐句播放文本列表
  Future<void> speakSentenceQueue(List<String> sentences, {bool Function()? shouldCancel}) async {
    if (!settings.enableTtsPlayback) return;
    for (final s in sentences) {
      enqueueSentence(s, shouldCancel: shouldCancel);
    }
    await waitForCompletion();
  }

  /// 试听指定的音色发音效果
  Future<void> previewVoice({required String voice, required String text}) async {
    await stop();
    final audioPath = await _edgeTtsService.synthesizeToFile(
      text,
      voice: voice,
      speed: settings.ttsSpeed,
    );
    if (audioPath != null && File(audioPath).existsSync()) {
      _audioPlayer ??= AudioPlayer();
      await _audioPlayer!.play(DeviceFileSource(audioPath));
    }
  }

  Future<void> _speakSentence(String sentence) async {
    _currentSpeakCompleter = Completer<void>();
    _isSpeaking = true;

    // 1. 如果用户启用了 Edge 神经网络引擎，且 EdgeTtsService 可用：优先使用超自然 Edge-TTS
    if (settings.ttsEngine == 'edge' && _edgeTtsService.isAvailable) {
      try {
        final audioPath = await _edgeTtsService.synthesizeToFile(
          sentence,
          voice: settings.edgeVoice,
          speed: settings.ttsSpeed,
        );

        if (audioPath != null && File(audioPath).existsSync()) {
          _audioPlayer ??= AudioPlayer();
          _audioPlayerCompleter = Completer<void>();
          _playerCompleteSub?.cancel();
          _playerCompleteSub = _audioPlayer!.onPlayerComplete.listen((_) {
            if (_audioPlayerCompleter != null && !_audioPlayerCompleter!.isCompleted) {
              _audioPlayerCompleter!.complete();
            }
          });

          await _audioPlayer!.play(DeviceFileSource(audioPath));
          await _audioPlayerCompleter!.future.timeout(
            Duration(seconds: (sentence.length * 0.8).clamp(3, 60).toInt()),
            onTimeout: () {},
          );

          // 播放完成，清理临时音频文件
          try {
            File(audioPath).deleteSync();
          } catch (_) {}

          _isSpeaking = false;
          if (_currentSpeakCompleter != null && !_currentSpeakCompleter!.isCompleted) {
            _currentSpeakCompleter!.complete();
          }
          return;
        }
      } catch (e) {
        debugPrint('[TtsService] Edge-TTS 播放异常，无缝降级为系统 SAPI: $e');
      }
    }

    // 2. 降级方案 / 用户指定系统 TTS：使用 flutter_tts (Windows SAPI5)
    try {
      await _flutterTts.speak(sentence);
      await _currentSpeakCompleter!.future.timeout(
        Duration(seconds: (sentence.length * 0.8).clamp(2, 60).toInt()),
        onTimeout: () {
          _isSpeaking = false;
        },
      );
    } catch (_) {
      _isSpeaking = false;
    }
  }

  void dispose() {
    stop();
    _playerCompleteSub?.cancel();
    _audioPlayer?.dispose();
    _edgeTtsService.dispose();
  }
}
