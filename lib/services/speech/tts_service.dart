import '../../core/ports/tts_port.dart';
import 'dart:async';
import 'dart:io';
import '../../core/models/app_settings.dart';
import '../../core/platform/audio_output_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import 'edge_tts_service.dart';

class TtsService implements TtsPort {
  @override
  void applyConfig(TtsConfig config) {
    settings.tts = config;
  }

  final AppSettings settings;
  late final PlatformTtsBackend _backend;
  late final EdgeTtsService _edgeTtsService;

  bool _isSpeaking = false;
  Completer<void>? _currentSpeakCompleter;
  int _speakGeneration = 0;

  /// 最近真正送到扬声器朗读过的文本（滚动窗口），供上层做声学回声拒识。
  ///
  /// - [_activeSpokenSentence]：当前正在外放的句子（即使单句朗读超过 5 秒也绝不提前过期）。
  /// - [_spokenHistory]：已播完（或刚被打断）的句子，从播完时刻起保留 [_echoMemoryWindow]，
  ///   覆盖扬声器残余混响与 ASR 切片尾延迟。
  String _activeSpokenSentence = '';
  final List<_SpokenChunk> _spokenHistory = [];
  static const Duration _echoMemoryWindow = Duration(seconds: 5);

  final List<_QueuedSentence> _sentenceQueue = [];
  bool _isQueueWorkerRunning = false;
  bool Function()? _currentShouldCancel;
  Completer<void>? _allFinishedCompleter;

  late final Future<void> _initFuture;

  TtsService({required this.settings}) {
    _backend = PlatformTtsBackend(settings: settings);
    _edgeTtsService = EdgeTtsService();
    _initFuture = _backend.init();
  }

  bool get isEdgeTtsAvailable => _edgeTtsService.isAvailable;

  @override
  bool get isSpeaking =>
      _isSpeaking || _sentenceQueue.isNotEmpty || _isQueueWorkerRunning;

  /// 过去约 5 秒内真正外放朗读过的文本（含当前正在朗读的长句）。
  ///
  /// 用于上层的声学回声拒识与回声剥离：外放声音被麦克风回采后再送 ASR，识别结果通常
  /// 就是该文本的近似子串（或夹杂了用户打断词的混合串）。超时条目在这里按需清理。
  @override
  String get recentlySpokenText {
    final cutoff = DateTime.now().subtract(_echoMemoryWindow);
    _spokenHistory.removeWhere((chunk) => chunk.at.isBefore(cutoff));
    final buffer = StringBuffer();
    for (final chunk in _spokenHistory) {
      buffer.write(chunk.text);
    }
    if (_activeSpokenSentence.isNotEmpty) {
      final current = buffer.toString();
      if (!current.endsWith(_activeSpokenSentence)) {
        buffer.write(_activeSpokenSentence);
      }
    }
    return buffer.toString();
  }

  /// 立即播放短控制语音（如“好的”、“已取消”），打断当前正在朗读的内容
  @override
  Future<void> speakImmediate(String text) async {
    if (!settings.enableTtsPlayback) return;
    await stop();
    await _speakSentence(text);
  }

  /// 停止播放（用于打断 Barge-in 或取消）
  @override
  Future<void> stop() async {
    final droppedQueue = _sentenceQueue.length;
    _speakGeneration++;
    if (_activeSpokenSentence.isNotEmpty || droppedQueue > 0 || _isSpeaking) {
      debugPrint(
        '[TtsService] stop() 打断播报：代系→$_speakGeneration，'
        '丢弃排队 $droppedQueue 句，正在播报='
        '"${_activeSpokenSentence.isEmpty ? '无' : _brief(_activeSpokenSentence)}"',
      );
    }
    if (_activeSpokenSentence.isNotEmpty) {
      _rememberSpoken(_activeSpokenSentence);
      _activeSpokenSentence = '';
    }
    _clearAndCleanupQueue();
    _isQueueWorkerRunning = false;
    _edgeTtsService.cancelAll();

    try {
      await _backend.stop();
      _isSpeaking = false;
      if (_currentSpeakCompleter != null &&
          !_currentSpeakCompleter!.isCompleted) {
        _currentSpeakCompleter!.complete();
      }
      if (_allFinishedCompleter != null &&
          !_allFinishedCompleter!.isCompleted) {
        _allFinishedCompleter!.complete();
      }
    } catch (_) {}
  }

  void _clearAndCleanupQueue() {
    for (final item in _sentenceQueue) {
      final fut = item.preSynthesizedPath;
      if (fut != null) {
        unawaited(
          fut.then((path) {
            if (path != null && File(path).existsSync()) {
              try {
                File(path).deleteSync();
              } catch (_) {}
            }
          }).catchError((_) {}),
        );
      }
    }
    _sentenceQueue.clear();
  }

  /// 将流式切句追加进顺序队列，后台单任务依次朗读，同时提前后台合成下一句避免句间断顿
  @override
  void enqueueSentence(String sentence, {bool Function()? shouldCancel}) {
    if (!settings.enableTtsPlayback) return;
    final clean = sentence.trim();
    if (clean.isEmpty) return;

    _currentShouldCancel = shouldCancel;
    Future<String?>? preSynth;
    if (settings.ttsEngine == 'edge' && _edgeTtsService.isAvailable) {
      preSynth = _edgeTtsService.synthesizeToFile(
        clean,
        voice: settings.edgeVoice,
        speed: settings.ttsSpeed,
      );
    }
    _sentenceQueue.add(
      _QueuedSentence(
        text: clean,
        preSynthesizedPath: preSynth,
      ),
    );

    if (_allFinishedCompleter == null || _allFinishedCompleter!.isCompleted) {
      _allFinishedCompleter = Completer<void>();
    }

    // 先打日志再启动 worker：worker 会同步取走首句，晚打会看不出真实入队顺序。
    debugPrint(
      '[TtsService] 入队播报 "${_brief(clean)}" '
      '(队列=${_sentenceQueue.length}, 引擎=${settings.ttsEngine}, '
      'edge就绪=${_edgeTtsService.isAvailable})',
    );

    if (!_isQueueWorkerRunning) {
      _startQueueWorker();
    }
  }

  Future<void> _startQueueWorker() async {
    _isQueueWorkerRunning = true;
    while (_sentenceQueue.isNotEmpty) {
      final reason = _currentShouldCancel != null && _currentShouldCancel!()
          ? '上层 shouldCancel 返回 true'
          : null;
      if (reason != null) {
        debugPrint(
          '[TtsService] 播报队列被取消：$reason，丢弃剩余 ${_sentenceQueue.length} 句'
          '（首句 "${_sentenceQueue.first.text.isEmpty ? '' : _brief(_sentenceQueue.first.text)}"）',
        );
        _clearAndCleanupQueue();
        break;
      }
      final item = _sentenceQueue.removeAt(0);
      await _speakSentence(
        item.text,
        preSynthesizedPath: item.preSynthesizedPath,
      );
    }
    _isQueueWorkerRunning = false;
    if (_sentenceQueue.isEmpty &&
        _allFinishedCompleter != null &&
        !_allFinishedCompleter!.isCompleted) {
      _allFinishedCompleter!.complete();
    }
  }

  /// 等待当前所有排队的句子全部发音完成
  @override
  Future<void> waitForCompletion() async {
    if (!_isQueueWorkerRunning && _sentenceQueue.isEmpty) {
      return;
    }
    if (_allFinishedCompleter != null && !_allFinishedCompleter!.isCompleted) {
      await _allFinishedCompleter!.future;
    }
  }

  /// 顺序逐句播放文本列表
  Future<void> speakSentenceQueue(
    List<String> sentences, {
    bool Function()? shouldCancel,
  }) async {
    if (!settings.enableTtsPlayback) return;
    for (final s in sentences) {
      enqueueSentence(s, shouldCancel: shouldCancel);
    }
    await waitForCompletion();
  }

  /// 试听指定的音色发音效果
  @override
  Future<void> previewVoice({
    required String voice,
    required String text,
  }) async {
    await stop();
    if (settings.ttsEngine == 'edge' && _edgeTtsService.isAvailable) {
      final audioPath = await _edgeTtsService.synthesizeToFile(
        text,
        voice: voice,
        speed: settings.ttsSpeed,
      );
      if (audioPath != null && File(audioPath).existsSync()) {
        await _backend.playAudioFile(
          audioPath,
          timeout: Duration(seconds: (text.length * 0.8).clamp(3, 60).toInt()),
        );
        try {
          File(audioPath).deleteSync();
        } catch (_) {}
        return;
      }
    }
    // 降级为系统 TTS 试听
    await _speakSentence(text);
  }

  /// 记录一段外放文本并刷新其时间戳，供 [recentlySpokenText] 做回声拒识与剥离。
  void _rememberSpoken(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    _spokenHistory.removeWhere((chunk) => chunk.text == clean);
    _spokenHistory.add(_SpokenChunk(clean, DateTime.now()));
  }

  bool _isCancelled(int generation) => _cancelReason(generation) != null;

  /// 返回取消原因，null 表示未取消。
  ///
  /// 区分“代系被 stop() 递增”与“上层 shouldCancel 回调返回 true（通常是状态离开
  /// playing）”，避免第二句凭空消失却查不到是谁取消的。
  String? _cancelReason(int generation) {
    if (generation != _speakGeneration) {
      return '代系已递增($generation→$_speakGeneration，说明期间发生过 stop)';
    }
    if (_currentShouldCancel != null && _currentShouldCancel!()) {
      return '上层 shouldCancel 返回 true（状态已离开 playing 或代系不匹配）';
    }
    return null;
  }

  /// 日志用短文本，避免整段回答刷屏。
  static String _brief(String text) {
    final clean = text.trim().replaceAll('\n', ' ');
    return clean.length <= 24 ? clean : '${clean.substring(0, 24)}…';
  }

  Future<void> _speakSentence(
    String sentence, {
    Future<String?>? preSynthesizedPath,
  }) async {
    final generation = _speakGeneration;
    await _initFuture;
    final preCancel = _cancelReason(generation);
    if (preCancel != null) {
      debugPrint(
        '[TtsService] 跳过播报（开始前已取消）"${_brief(sentence)}"：$preCancel',
      );
      return;
    }

    final sw = Stopwatch()..start();
    _currentSpeakCompleter = Completer<void>();
    _isSpeaking = true;
    _activeSpokenSentence = sentence.trim();
    _rememberSpoken(sentence);

    try {
      // 1. 如果用户启用了 Edge 神经网络引擎，且 EdgeTtsService 可用：优先使用超自然 Edge-TTS
      if (settings.ttsEngine == 'edge' && _edgeTtsService.isAvailable) {
        try {
          final synthSw = Stopwatch()..start();
          final audioPath = await (preSynthesizedPath ??
              _edgeTtsService.synthesizeToFile(
                sentence,
                voice: settings.edgeVoice,
                speed: settings.ttsSpeed,
              ));
          debugPrint(
            '[TtsService] Edge 合成完成 ${synthSw.elapsedMilliseconds}ms '
            '"${_brief(sentence)}" 产物=${audioPath == null ? 'null' : '已生成'}',
          );
          if (_isCancelled(generation)) {
            debugPrint(
              '[TtsService] 跳过播报（合成完成时已被取消）"${_brief(sentence)}"：'
              '${_cancelReason(generation)}',
            );
            if (audioPath != null && File(audioPath).existsSync()) {
              try {
                File(audioPath).deleteSync();
              } catch (_) {}
            }
            return;
          }

          if (audioPath != null && File(audioPath).existsSync()) {
            final playSw = Stopwatch()..start();
            await _backend.playAudioFile(
              audioPath,
              timeout: Duration(
                seconds: (sentence.length * 1.0 + 8).clamp(10, 90).toInt(),
              ),
            );
            debugPrint(
              '[TtsService] 播放结束 ${playSw.elapsedMilliseconds}ms '
              '"${_brief(sentence)}"',
            );

            // 播放完成，清理临时音频文件
            try {
              File(audioPath).deleteSync();
            } catch (_) {}

            return;
          }
          debugPrint(
            '[TtsService] Edge 合成未产出可用文件，降级系统 TTS：'
            '"${_brief(sentence)}"',
          );
        } catch (e) {
          if (_isCancelled(generation)) {
            debugPrint(
              '[TtsService] 跳过播报（合成异常且已取消）"${_brief(sentence)}"：'
              '${_cancelReason(generation)}',
            );
            return;
          }
          debugPrint('[TtsService] Edge-TTS 播放异常，无缝降级为系统 TTS: $e');
        }
      }

      if (_isCancelled(generation)) {
        debugPrint(
          '[TtsService] 跳过系统 TTS 播报（已取消）"${_brief(sentence)}"：'
          '${_cancelReason(generation)}',
        );
        return;
      }

      // 2. 降级方案 / 用户指定系统 TTS
      try {
        final sysSw = Stopwatch()..start();
        await _backend.speakSystemTts(
          sentence,
          timeout: Duration(
            seconds: (sentence.length * 1.0 + 8).clamp(10, 90).toInt(),
          ),
        );
        debugPrint(
          '[TtsService] 系统 TTS 播放结束 ${sysSw.elapsedMilliseconds}ms '
          '"${_brief(sentence)}"',
        );
      } catch (e) {
        debugPrint('[TtsService] 系统 TTS 播放异常: $e');
        _isSpeaking = false;
      }
    } finally {
      debugPrint(
        '[TtsService] 句结束 总耗时 ${sw.elapsedMilliseconds}ms '
        '"${_brief(sentence)}"',
      );
      // 朗读结束（或被打断）时再次刷新该句的时间戳，确保长句播完后仍有完整的尾音回声记忆窗口。
      _rememberSpoken(sentence);
      if (_activeSpokenSentence == sentence.trim()) {
        _activeSpokenSentence = '';
      }
      _isSpeaking = false;
      if (_currentSpeakCompleter != null &&
          !_currentSpeakCompleter!.isCompleted) {
        _currentSpeakCompleter!.complete();
      }
    }
  }

  @override
  void dispose() {
    stop();
    _backend.dispose();
    _edgeTtsService.dispose();
  }
}

class _QueuedSentence {
  final String text;
  final Future<String?>? preSynthesizedPath;

  const _QueuedSentence({
    required this.text,
    this.preSynthesizedPath,
  });
}

/// 一段已外放朗读的文本及其朗读起始时间，用于回声拒识的时间窗口判定。
class _SpokenChunk {
  final String text;
  final DateTime at;

  const _SpokenChunk(this.text, this.at);
}
