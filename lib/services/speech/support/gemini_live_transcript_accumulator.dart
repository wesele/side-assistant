import 'dart:async';
import 'dart:convert';

import '../../../core/platform/foundation_bridge.dart';
import '../asr_service.dart';

/// Gemini Live 转写文本的纯规则：语言过滤、空格归一、子轮次拼接与最终清洗。
///
/// 全部是静态纯函数，便于脱离网络直接单测。
class GeminiLiveTranscriptText {
  const GeminiLiveTranscriptText._();

  static final RegExp _hanRegExp = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );
  static final RegExp _kanaRegExp = RegExp(r'[\u3040-\u30FF]');
  static final RegExp _hangulRegExp = RegExp(r'[\uAC00-\uD7AF]');
  static final RegExp _chineseSpacingRegExp = RegExp(
    r'([\u4E00-\u9FFF])\s+(?=[\u4E00-\u9FFF])',
  );

  /// 判断识别结果是否“像中文”。
  ///
  /// Gemini 是自动语种检测的多语种模型（官方支持 85+ 语种与中英混说），
  /// `inputAudioTranscription.languageCodes` 只是偏置：实测它能稳定把粤语转成
  /// 普通话，但不会阻止模型把环境里的西语/日语/韩语原样转写出来。
  /// 语音助手只接受中文指令，因此这里做结果侧过滤：
  /// - 至少要有汉字；
  /// - 日文假名或韩文数量不能超过汉字数量（避免把日/韩语句子当成中文）；
  /// - 中英混说（如“打开 Spotify”）仍然保留，因为汉字存在且没有假名/韩文。
  static bool isChineseLike(String text) {
    if (text.trim().isEmpty) return false;
    final han = _hanRegExp.allMatches(text).length;
    if (han == 0) return false;
    final kana = _kanaRegExp.allMatches(text).length;
    final hangul = _hangulRegExp.allMatches(text).length;
    return kana <= han && hangul <= han;
  }

  /// 去掉汉字之间由 interim 带出的空格（“开放 时间” -> “开放时间”）。
  /// 中英混说时保留英文单词之间的空格。
  static String normalizeChineseSpacing(String text) {
    return text.replaceAllMapped(_chineseSpacingRegExp, (match) => match[1]!);
  }

  /// 合并同一段语音内的多个服务端 VAD 子轮次文本。
  ///
  /// - 必须把 [completedTurns]（已归档的前半句）与当前子轮次一并拼接，避免用户
  ///   在说“回答”前轻微换气时，中间结果或最终结果只剩“回答”而丢掉前半句提问；
  /// - 若整段里已经有中文子句，则保留穿插其中的短英文词（如 "Spotify"）或数字
  ///   子句（如 "123"），仅剔除假名/韩文或超过 3 个单词的纯外语背景串音。
  static String combineSubTurns({
    required List<String> completedTurns,
    required String currentTurnFinalText,
    required String interimText,
  }) {
    final candidates = <String>[
      for (final turn in completedTurns)
        if (turn.trim().isNotEmpty) turn,
      if (currentTurnFinalText.trim().isNotEmpty)
        currentTurnFinalText
      else if (interimText.trim().isNotEmpty)
        interimText,
    ];
    if (candidates.isEmpty) return '';

    final anyChinese = candidates.any(isChineseLike);
    if (!anyChinese) return '';

    final filtered = <String>[
      for (final seg in candidates)
        if (!isForeignNoiseTurn(seg)) seg,
    ];
    return filtered.join();
  }

  static bool isForeignNoiseTurn(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    if (isChineseLike(trimmed)) return false;
    if (_kanaRegExp.hasMatch(trimmed) || _hangulRegExp.hasMatch(trimmed)) {
      return true;
    }
    final latinWords = RegExp(r'[A-Za-zÀ-ÿ]+').allMatches(trimmed).length;
    return latinWords > 3;
  }

  /// 对累积文本做后处理 + 语种过滤，返回可提交给控制器的最终文本。
  static String finalize(
    String raw, {
    required bool wakeContext,
    required double audioSeconds,
    int elapsedMs = 0,
  }) {
    final cleaned = normalizeChineseSpacing(
      postProcessAsrText(raw, wakeContext: wakeContext),
    );
    if (cleaned.isEmpty) return '';
    if (!isChineseLike(cleaned)) {
      debugPrint(
        '[GeminiLiveAsrService] 丢弃非中文识别结果 '
        '(${audioSeconds.toStringAsFixed(2)}s): "$cleaned"',
      );
      return '';
    }
    debugPrint(
      '[GeminiLiveAsrService] 识别完成 '
      '(${audioSeconds.toStringAsFixed(2)}s 音频, '
      '耗时 ${elapsedMs}ms): "$cleaned"',
    );
    return cleaned;
  }
}

/// Gemini Live 服务端消息解码 + 转写文本累积。
///
/// 职责边界：
/// - 把 WebSocket 收到的帧（String / List<int> / JSON）解码成消息 Map；
/// - 按“连接代次”（connectionId）丢弃旧连接的迟到消息；
/// - 累积 `interimInputTranscription` / `inputTranscription` 与已归档的子轮次，
///   并在 `generationComplete` / `turnComplete` 时按协议决定是否收尾。
///
/// 不持有 socket、不持有 Completer：所有副作用（收尾、setup 完成、错误上报、
/// 中间结果回调）都通过构造参数里的回调交给调用方，因此可以脱离网络单测。
class GeminiLiveTranscriptAccumulator {
  GeminiLiveTranscriptAccumulator({
    required this.activeConnectionId,
    required this.partialTextCallback,
    this.onSetupComplete,
    this.onServerError,
    this.onGoAway,
    this.onMessageReceived,
    this.onFinish,
  });

  /// 当前有效的连接代次。代次不匹配的消息（旧连接迟到）必须整体丢弃。
  final int Function() activeConnectionId;

  /// 取当前生效的中间结果回调（运行期可能被替换，必须每次读取）。
  final void Function(String text)? Function() partialTextCallback;

  /// 收到 `setupComplete`。
  final void Function()? onSetupComplete;

  /// 服务端下发 `error`（已提取为可读文本）。
  final void Function(String message)? onServerError;

  /// 服务端下发 `goAway`（会话即将被服务端关闭）。
  final void Function(Map<dynamic, dynamic> info)? onGoAway;

  /// 收到任意一条合法服务端消息（用于重置静默兜底计时）。
  final void Function()? onMessageReceived;

  /// 协议判定本段可以收尾。
  final void Function()? onFinish;

  final List<String> _completedTurns = <String>[];
  String _currentTurnFinalText = '';
  String _interimText = '';
  bool _generationDone = false;
  bool _turnCompleteReceived = false;
  bool _audioEnded = false;
  bool _disposed = false;
  Timer? _finishGraceTimer;

  // ---- 中间结果提前回调 ----
  // VAD 切段后，Gemini 会在最终结果之前先返回 interimInputTranscription。
  // 把这部分文本（防抖后）交给控制器，可以在“回答”刚被识别出来时就提交大模型，
  // 不必等 generationComplete / ACTIVITY_END 的完整收尾。
  bool _emitPartial = false;
  bool _wakeContext = false;
  String _lastEmittedPartial = '';
  Timer? _partialDebounceTimer;

  /// 已归档的前半句子轮次（用户换气时服务端会切成多段）。
  List<String> get completedTurns => List<String>.unmodifiable(_completedTurns);

  String get currentTurnFinalText => _currentTurnFinalText;

  String get interimText => _interimText;

  /// 是否已经收到过收尾信号（generationComplete / turnComplete）。
  bool get generationDone => _generationDone;

  bool get turnCompleteReceived => _turnCompleteReceived;

  /// 最终转写是否已经到齐。
  ///
  /// 实测（`tool/probes/gemini_timing_probe.dart`）`inputTranscription` 与
  /// `generationComplete` 在同一批消息里到达，且 `turnComplete` 在转写模型上
  /// 根本不会出现。因此只要最终文本已经在手，就没必要再等 250ms 收尾宽限。
  bool get hasFinalTranscript => _currentTurnFinalText.isNotEmpty;

  /// 是否已经发过 `audioStreamEnd`：只有发过之后，服务端的收尾信号才算整句结束。
  bool get audioEnded => _audioEnded;

  /// 当前累积的完整文本（已归档子轮次 + 当前子轮次）。
  String get combinedText => GeminiLiveTranscriptText.combineSubTurns(
        completedTurns: _completedTurns,
        currentTurnFinalText: _currentTurnFinalText,
        interimText: _interimText,
      );

  /// 新的一段 turn 开始：清空上一段的转写累积。
  void resetTurn({bool emitPartial = false, bool wakeContext = false}) {
    _completedTurns.clear();
    _currentTurnFinalText = '';
    _interimText = '';
    _generationDone = false;
    _turnCompleteReceived = false;
    _audioEnded = false;
    _emitPartial = emitPartial;
    _wakeContext = wakeContext;
    _lastEmittedPartial = '';
    cancelFinishGrace();
    cancelPartialEmit();
  }

  /// 本段 turn 结束：停掉所有与文本相关的计时并清空中间结果状态。
  void endTurn() {
    _emitPartial = false;
    _wakeContext = false;
    _lastEmittedPartial = '';
    cancelFinishGrace();
    cancelPartialEmit();
  }

  /// 已发出 `audioStreamEnd`：只有发过之后，服务端的收尾信号才算整句结束。
  void markAudioEnded() {
    _audioEnded = true;
  }

  void markDisposed() {
    _disposed = true;
    cancelFinishGrace();
    cancelPartialEmit();
  }

  /// 中间结果防抖：等 40ms 没有新的 interim 再回调，兼顾结束词极速触发与
  /// 避免在同一微秒批次里重复触发控制器。
  void _schedulePartialEmit() {
    if (!_emitPartial || _wakeContext || partialTextCallback() == null) return;

    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = Timer(const Duration(milliseconds: 40), () {
      _partialDebounceTimer = null;
      _emitPartialNow();
    });
  }

  void _emitPartialNow() {
    final callback = partialTextCallback();
    if (!_emitPartial || _wakeContext || callback == null) return;

    final raw = combinedText.trim();
    if (raw.isEmpty) return;

    final cleaned = GeminiLiveTranscriptText.normalizeChineseSpacing(
      postProcessAsrText(raw, wakeContext: false),
    );
    if (cleaned.isEmpty || cleaned == _lastEmittedPartial) return;
    if (!GeminiLiveTranscriptText.isChineseLike(cleaned)) {
      debugPrint('[GeminiLiveAsrService] 丢弃非中文中间结果: "$cleaned"');
      return;
    }

    _lastEmittedPartial = cleaned;
    debugPrint('[GeminiLiveAsrService] 中间结果: "$cleaned"');
    callback(cleaned);
  }

  void cancelPartialEmit() {
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;
  }

  /// `generationComplete` 到了但最终转写还没到：给服务端 250ms 补发，
  /// 避免下一段复用连接时卡住。
  void armFinishGrace() {
    cancelFinishGrace();
    _finishGraceTimer = Timer(const Duration(milliseconds: 250), () {
      _finishGraceTimer = null;
      onFinish?.call();
    });
  }

  void cancelFinishGrace() {
    _finishGraceTimer?.cancel();
    _finishGraceTimer = null;
  }

  /// 处理一条服务端消息。[connectionId] 是产生该消息的连接代次。
  void handleMessage(dynamic raw, int connectionId) {
    if (_disposed || connectionId != activeConnectionId()) return;

    final message = _decode(raw);
    if (message == null) return;

    // 每收到一条服务端消息就重置“静默兜底”计时：模型还在持续吐 interim 时
    // 不要提前截断；只有长时间完全没有消息才收尾。
    onMessageReceived?.call();

    if (message.containsKey('setupComplete')) {
      onSetupComplete?.call();
      return;
    }

    // 转写模型单条会话上限约 10 分钟，到点前服务端会发 goAway 再关闭。
    // 空闲时主动收掉连接，避免下一段音频写进一条正在关闭的 socket 里。
    final goAway = message['goAway'];
    if (goAway is Map) {
      debugPrint('[GeminiLiveAsrService] 服务端即将断开: $goAway');
      onGoAway?.call(goAway);
      return;
    }

    final error = message['error'];
    if (error != null) {
      final text = error is Map
          ? (error['message']?.toString() ?? error.toString())
          : error.toString();
      onServerError?.call(text);
      return;
    }

    final voiceActivity = message['voiceActivity'];
    if (voiceActivity is Map && voiceActivity['type'] == 'ACTIVITY_START') {
      // 新的一段语音开始：把上一段的最终文本归档，继续累积。
      _archiveCurrentFinal();
      _interimText = '';
      _generationDone = false;
      _turnCompleteReceived = false;
      cancelFinishGrace();
    }

    final serverContent = message['serverContent'];
    if (serverContent is! Map) return;

    final interim = serverContent['interimInputTranscription'];
    if (interim is Map && interim['text'] is String) {
      // 若上一段子轮次已经收到过最终文本（inputTranscription），说明当前
      // interim 属于新的子轮次（即使服务端未先发 ACTIVITY_START），先归档上一段。
      _archiveCurrentFinal();
      _interimText = interim['text'] as String;
      _schedulePartialEmit();
    }

    final finalTranscription = serverContent['inputTranscription'];
    if (finalTranscription is Map && finalTranscription['text'] is String) {
      final text = finalTranscription['text'] as String;
      if (text.isNotEmpty) {
        // 同一个 turn 内如果收到修订版，用最新版本覆盖而不是重复追加。
        _currentTurnFinalText = text;
        _interimText = '';
        _schedulePartialEmit();
      }
    }

    if (serverContent['turnComplete'] == true) {
      _turnCompleteReceived = true;
      debugPrint('[GeminiLiveAsrService] 收到 turnComplete');
    }

    if (serverContent['generationComplete'] == true ||
        serverContent['turnComplete'] == true) {
      _generationDone = true;
      // 边说边传阶段（还没发 audioStreamEnd）服务端也可能给收尾信号——
      // 那是它内部 VAD 的一段结束，不是整句结束，不能提前收尾。
      if (!_audioEnded) return;
      if (_turnCompleteReceived || hasFinalTranscript) {
        onFinish?.call();
      } else {
        armFinishGrace();
      }
    }
  }

  void _archiveCurrentFinal() {
    if (_currentTurnFinalText.isEmpty) return;
    _completedTurns.add(_currentTurnFinalText);
    _currentTurnFinalText = '';
  }

  /// 解码一帧服务端消息；畸形/非对象 JSON 一律返回 null。
  ///
  /// Gemini Live 的响应有时以二进制帧返回（dart:io 会给出 List<int>），
  /// 需要先按 UTF-8 解码，不能只处理 String。
  static Map<String, dynamic>? _decode(dynamic raw) {
    String? text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      try {
        text = utf8.decode(raw);
      } catch (_) {
        return null;
      }
    }
    if (text == null || text.isEmpty) return null;

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }
}
