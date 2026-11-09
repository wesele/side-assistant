import 'dart:async';

/// Gemini Live 深度思考 (Advanced Mode) 轮次延期与状态生命周期管理器
///
/// 纯 Dart 实现，负责管理 Advanced 模式下的：
/// 1. 延期轮次状态跟踪 (`isTurnDeferred`) 与超时安全兜底 (默认 90s)
/// 2. 跨分段模型回答文本拼接与累加 (`accumulatedAssistantText`)
/// 3. 服务端交互态 (`interactionStatus` -> `lastInteractionInProgress`) 与工具调用 ID 跟踪
class GeminiLiveDeferredTurnManager {
  Duration timeout;
  bool isTurnDeferred = false;
  bool lastInteractionInProgress = false;
  final Set<String> _pendingToolCallIds = <String>{};
  bool isCapturingPhoto = false;
  String accumulatedAssistantText = '';
  Timer? _safetyTimer;

  GeminiLiveDeferredTurnManager({
    this.timeout = const Duration(seconds: 90),
  });

  bool get isDeferredTimerActive =>
      _safetyTimer != null && _safetyTimer!.isActive;

  Set<String> get pendingToolCallIds => Set.unmodifiable(_pendingToolCallIds);

  bool hasPendingToolCalls({bool isToolProgressRunning = false}) =>
      _pendingToolCallIds.isNotEmpty ||
      isCapturingPhoto ||
      isToolProgressRunning;

  void trackPendingToolCall(String id) {
    if (id.isNotEmpty) _pendingToolCallIds.add(id);
  }

  void removePendingToolCall(String id) {
    _pendingToolCallIds.remove(id);
  }

  void removePendingToolCalls(Iterable<String> ids) {
    _pendingToolCallIds.removeAll(ids);
  }

  /// 在当前累积文本后追加新一段已完成的助手回复
  void finalizeSegmentText(String currentReply) {
    final trimmed = currentReply.trim();
    if (trimmed.isEmpty) return;
    if (accumulatedAssistantText.isNotEmpty) {
      accumulatedAssistantText = '$accumulatedAssistantText\n$trimmed';
    } else {
      accumulatedAssistantText = trimmed;
    }
  }

  /// 组合历史累加文本与当前流式/实时片段
  String combineWithAccumulated(String currentText) {
    if (accumulatedAssistantText.isEmpty) return currentText;
    if (currentText.isEmpty) return accumulatedAssistantText;
    return '$accumulatedAssistantText\n$currentText';
  }

  /// 组合历史累加文本、前置输出与工具提示
  String formatBubbleWithToolStatus({
    required String preToolReply,
    required String statusDisplay,
  }) {
    final prefix = accumulatedAssistantText.isNotEmpty
        ? (preToolReply.isNotEmpty
            ? '$accumulatedAssistantText\n$preToolReply'
            : accumulatedAssistantText)
        : preToolReply;
    return prefix.isNotEmpty ? '$prefix\n\n$statusDisplay' : statusDisplay;
  }

  /// 标记进入延期轮次，并启动安全超时定时器
  void markDeferred({required void Function() onTimeout}) {
    isTurnDeferred = true;
    startSafetyTimer(onTimeout: onTimeout);
  }

  void startSafetyTimer({required void Function() onTimeout}) {
    cancelSafetyTimer();
    _safetyTimer = Timer(timeout, onTimeout);
  }

  void cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  /// 彻底重置延期轮次状态与文本累积
  void reset() {
    cancelSafetyTimer();
    isTurnDeferred = false;
    lastInteractionInProgress = false;
    accumulatedAssistantText = '';
    isCapturingPhoto = false;
    _pendingToolCallIds.clear();
  }

  void dispose() {
    reset();
  }
}
