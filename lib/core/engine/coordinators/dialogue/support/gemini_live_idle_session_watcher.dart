import 'dart:async';

import '../../../../models/app_settings.dart';
import '../../../../models/assistant_status.dart';
import '../../../../ports/gemini_live_session_port.dart';
import '../../../../ports/session_message_port.dart';
import '../dialogue_state_machine.dart';

/// 管理 Gemini Live 话筒常驻启停的新会话重置与长时间无对话自动开新会话计时器。
class GeminiLiveIdleSessionWatcher {
  Timer? _timer;
  bool _disposed = false;
  bool _idleInFlight = false;
  bool micSessionOpen = false;
  Future<void>? _connectInFlight;
  Future<void>? _disconnectInFlight;

  bool get isTimerActive => _timer != null && _timer!.isActive;

  void cancelIdle() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> performAutoNewSession({
    required void Function() resetLocalTurnState,
    required Future<void> Function()? onAutoNewSession,
    required SessionMessagePort sessionMessagePort,
    required GeminiLiveSessionPort liveSession,
  }) async {
    resetLocalTurnState();
    await (onAutoNewSession?.call() ?? sessionMessagePort.startNewSession());
    await liveSession.syncSessionContext(const [], resetSession: true);
  }

  void scheduleIdle({
    required AppSettings settings,
    required bool Function() hasActiveTurn,
    required SessionMessagePort sessionMessagePort,
    required GeminiLiveSessionPort liveSession,
    required DialogueStateMachine stateMachine,
    required void Function() resetLocalTurnState,
    required Future<void> Function()? onAutoNewSession,
  }) {
    cancelIdle();
    final timeoutSeconds = settings.geminiLiveIdleNewSessionSeconds;
    if (_disposed ||
        !micSessionOpen ||
        !settings.isGeminiLiveMode ||
        timeoutSeconds <= 0) {
      return;
    }
    _timer = Timer(Duration(seconds: timeoutSeconds), () {
      if (_disposed ||
          _idleInFlight ||
          !micSessionOpen ||
          !settings.isGeminiLiveMode ||
          hasActiveTurn() ||
          sessionMessagePort.messages.isEmpty) {
        return;
      }
      _idleInFlight = true;
      unawaited(() async {
        try {
          await performAutoNewSession(
            resetLocalTurnState: resetLocalTurnState,
            onAutoNewSession: onAutoNewSession,
            sessionMessagePort: sessionMessagePort,
            liveSession: liveSession,
          );
          if (micSessionOpen &&
              settings.isGeminiLiveMode &&
              liveSession.isActive) {
            stateMachine.setStatus(
              AssistantStatus.listeningContent,
              '长时间未对话，已自动开启新会话，请直接说话',
            );
          }
        } finally {
          _idleInFlight = false;
        }
      }());
    });
  }

  Future<void> handleMicChanged({
    required bool isListening,
    required GeminiLiveSessionPort liveSession,
    required SessionMessagePort sessionMessagePort,
    required DialogueStateMachine stateMachine,
    required void Function() resetLocalTurnState,
    required Future<void> Function()? onAutoNewSession,
    required void Function() onScheduleIdle,
  }) async {
    if (!isListening) {
      final shouldReset = micSessionOpen ||
          liveSession.isActive ||
          sessionMessagePort.messages.isNotEmpty;
      micSessionOpen = false;
      cancelIdle();
      if (_disconnectInFlight != null) {
        await _disconnectInFlight;
        return;
      }
      final fut = () async {
        if (_connectInFlight != null) {
          try {
            await _connectInFlight;
          } catch (_) {}
        }
        if (micSessionOpen || _disposed) return;
        resetLocalTurnState();
        await liveSession.disconnect();
        if (shouldReset) {
          await performAutoNewSession(
            resetLocalTurnState: resetLocalTurnState,
            onAutoNewSession: onAutoNewSession,
            sessionMessagePort: sessionMessagePort,
            liveSession: liveSession,
          );
        }
        stateMachine.setStatus(AssistantStatus.idle, '话筒已静音');
      }();
      _disconnectInFlight = fut;
      try {
        await fut;
      } finally {
        if (identical(_disconnectInFlight, fut)) _disconnectInFlight = null;
      }
      return;
    }

    if (_connectInFlight != null) {
      await _connectInFlight;
      return;
    }
    if (micSessionOpen && liveSession.isReady && liveSession.isActive) {
      stateMachine.enterContinuousMode();
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        'Gemini 3.8 Live 全双工通话中，请直接说话',
      );
      onScheduleIdle();
      return;
    }
    final startFresh = !micSessionOpen;
    micSessionOpen = true;
    final fut = () async {
      if (_disconnectInFlight != null) {
        try {
          await _disconnectInFlight;
        } catch (_) {}
      }
      if (!micSessionOpen || _disposed) return;
      if (startFresh) {
        await performAutoNewSession(
          resetLocalTurnState: resetLocalTurnState,
          onAutoNewSession: onAutoNewSession,
          sessionMessagePort: sessionMessagePort,
          liveSession: liveSession,
        );
        if (!micSessionOpen || _disposed) return;
      }
      stateMachine.enterContinuousMode();
      stateMachine.setStatus(
        AssistantStatus.listeningContent,
        '正在连接 Gemini 3.8 Live...',
      );
      final ok = await liveSession.connect();
      if (!micSessionOpen || _disposed) {
        await liveSession.disconnect();
        return;
      }
      final status = (ok || liveSession.isActive)
          ? AssistantStatus.listeningContent
          : AssistantStatus.idle;
      final hint = ok
          ? 'Gemini 3.8 Live 全双工通话中，请直接说话'
          : (liveSession.lastError ??
              (liveSession.isActive
                  ? '正在切换 Gemini Live 备用 Key...'
                  : 'Gemini Live 连接失败'));
      stateMachine.setStatus(status, hint);
      if (ok || liveSession.isActive) onScheduleIdle();
    }();
    _connectInFlight = fut;
    try {
      await fut;
    } finally {
      if (identical(_connectInFlight, fut)) _connectInFlight = null;
    }
  }

  void dispose() {
    _disposed = true;
    micSessionOpen = false;
    cancelIdle();
  }
}
