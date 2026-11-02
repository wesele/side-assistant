import 'dart:convert';

/// 大模型对话决策结果
class LlmDialogueDecision {
  /// 意图类型：
  /// - `start_or_continue`: 包含唤醒、提问、或在连续对话中继续交流
  /// - `new_session`: 主人明确要求新起话题、重置或重新开始会话
  /// - `exit`: 主人明确要求结束对话、退下、退出连续对话
  /// - `ignore`: 主人非对话语音（旁白、自言自语、与他人交谈等）
  final String intent;

  /// 是否需要向主人回复语音与文字
  final bool shouldReply;

  /// 回复正文内容（当 shouldReply 为 false 时为空）
  final String reply;

  const LlmDialogueDecision({
    required this.intent,
    required this.shouldReply,
    required this.reply,
  });

  bool get isStartOrContinue => intent == 'start_or_continue';
  bool get isNewSession => intent == 'new_session';
  bool get isExit => intent == 'exit';
  bool get isIgnore => intent == 'ignore' || !shouldReply;

  @override
  String toString() =>
      'LlmDialogueDecision(intent: $intent, shouldReply: $shouldReply, replyLen: ${reply.length})';
}

/// 流式增量 JSON 意图与回复解析器
///
/// 能够从流式到达的 JSON token 片段中实时提取 intent、should_reply，
/// 并在 reply 字段生成时无缝以流式文本输出，实现首字极速发音（TTFA）。
class StreamingJsonReplyParser {
  final StringBuffer _rawBuffer = StringBuffer();
  final StringBuffer _replyBuffer = StringBuffer();

  bool _intentResolved = false;
  String _intent = 'start_or_continue';
  bool _shouldReply = true;

  bool _inReplyString = false;
  bool _replyCompleted = false;
  bool _escapeNext = false;

  void Function(String intent, bool shouldReply)? onIntentResolved;
  void Function(String chunk)? onReplyChunk;

  /// 处理每一个从 LLM 到达的流式 token 片段
  void feed(String token) {
    if (token.isEmpty) return;
    _rawBuffer.write(token);

    // 尚未解析出意图时，尝试在当前接收到的前缀中探测
    if (!_intentResolved) {
      _tryResolveIntent();
    }

    // 增量解析 reply 字符串内容
    _processIncrementalReply(token);
  }

  void _tryResolveIntent() {
    final text = _rawBuffer.toString();

    // 探测 should_reply
    final shouldReplyMatch = RegExp(
      r'"should_reply"\s*:\s*(true|false)',
      caseSensitive: false,
    ).firstMatch(text);

    // 探测 intent
    final intentMatch = RegExp(
      r'"intent"\s*:\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(text);

    if (shouldReplyMatch != null || intentMatch != null) {
      if (shouldReplyMatch != null) {
        _shouldReply = shouldReplyMatch.group(1)!.toLowerCase() == 'true';
      }
      if (intentMatch != null) {
        _intent = intentMatch.group(1)!.toLowerCase();
      }

      // 只要匹配到了至少一个核心控制字段，触发意图回调
      if (shouldReplyMatch != null && intentMatch != null) {
        _intentResolved = true;
        onIntentResolved?.call(_intent, _shouldReply);
      }
    }
  }

  void _processIncrementalReply(String token) {
    if (_replyCompleted) return;

    final full = _rawBuffer.toString();

    // 如果还没有进入 reply 字段，检查是否已出现 "reply"\s*:\s*"
    if (!_inReplyString) {
      final replyStartMatch = RegExp(r'"reply"\s*:\s*"').firstMatch(full);
      if (replyStartMatch != null) {
        _inReplyString = true;
        final startIdx = replyStartMatch.end;
        // 把从 startIdx 到当前 full 结尾的内容提取出来作为首批 reply 内容
        final candidate = full.substring(startIdx);
        _consumeReplySubstring(candidate);
      }
      return;
    }

    // 已处于 reply 字段中，直接消费新追加的 token
    _consumeReplySubstring(token);
  }

  void _consumeReplySubstring(String chunk) {
    if (_replyCompleted || chunk.isEmpty) return;

    final emitBuf = StringBuffer();

    for (int i = 0; i < chunk.length; i++) {
      final char = chunk[i];

      if (_escapeNext) {
        _escapeNext = false;
        switch (char) {
          case 'n':
            emitBuf.write('\n');
            break;
          case 'r':
            emitBuf.write('\r');
            break;
          case 't':
            emitBuf.write('\t');
            break;
          case '"':
            emitBuf.write('"');
            break;
          case '\\':
            emitBuf.write('\\');
            break;
          default:
            emitBuf.write(char);
            break;
        }
        continue;
      }

      if (char == '\\') {
        _escapeNext = true;
        continue;
      }

      if (char == '"') {
        // 遇到非转义的双引号，说明 reply 字段内容结束
        _replyCompleted = true;
        break;
      }

      emitBuf.write(char);
    }

    final emitted = emitBuf.toString();
    if (emitted.isNotEmpty) {
      _replyBuffer.write(emitted);
      if (_shouldReply) {
        onReplyChunk?.call(emitted);
      }
    }
  }

  /// 结束流式接收并输出最终判定
  LlmDialogueDecision finish() {
    final raw = _rawBuffer.toString().trim();

    // 优先尝试标准 JSON 解析
    try {
      // 提取最外层大括号
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start != -1 && end != -1 && end > start) {
        final jsonStr = raw.substring(start, end + 1);
        final map = jsonDecode(jsonStr);
        if (map is Map) {
          final intent = (map['intent']?.toString() ?? _intent).toLowerCase();
          final shouldReply = map.containsKey('should_reply')
              ? (map['should_reply'] is bool
                  ? map['should_reply'] as bool
                  : (map['should_reply']?.toString().toLowerCase() == 'true'))
              : (intent != 'ignore');
          final reply = map['reply']?.toString() ?? _replyBuffer.toString();

          return LlmDialogueDecision(
            intent: intent,
            shouldReply: shouldReply,
            reply: shouldReply ? reply.trim() : '',
          );
        }
      }
    } catch (_) {
      // JSON 格式轻微残缺时，采用增量正则解析兜底
    }

    // 若已经解析到 reply 内容或意图
    if (_replyBuffer.isNotEmpty || _intentResolved) {
      return LlmDialogueDecision(
        intent: _intent,
        shouldReply: _shouldReply,
        reply: _shouldReply ? _replyBuffer.toString().trim() : '',
      );
    }

    // 兜底机制：若模型完全没有输出 JSON 格式（直接吐露回答），自动视为需要回复的连续问答
    if (raw.isNotEmpty) {
      return LlmDialogueDecision(
        intent: 'start_or_continue',
        shouldReply: true,
        reply: raw,
      );
    }

    return const LlmDialogueDecision(
      intent: 'ignore',
      shouldReply: false,
      reply: '',
    );
  }
}
