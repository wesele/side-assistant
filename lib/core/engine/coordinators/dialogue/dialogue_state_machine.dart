import 'dart:async';

import '../../../constants/app_constants.dart';
import '../../../models/app_settings.dart';
import '../../../models/assistant_status.dart';
import '../../../platform/foundation_bridge.dart';
import '../../../ports/audio_stream_control_port.dart';
import '../../../ports/tts_port.dart';

/// 对话状态类型定义，直接复用标准助手状态枚举
typedef DialogueState = AssistantStatus;

/// 对话状态机与生命周期管理组件 (DialogueStateMachine)
///
/// 专职负责对话有限状态跃迁、连续对话模式生命周期、状态文案渲染，
/// 以及统一协调 5 大异步超时计时器（静音超时、连续对话超时、空闲卫生、LightRAG 超时与无唤醒淡出）。
/// 纯 Dart 实现，零 `dart:ui` 或 `package:flutter` 依赖。
class DialogueStateMachine {
  AppSettings settings;
  final AudioStreamControlPort? audioControlPort;
  final TtsPort? ttsService;

  // 依赖解耦查询与回调
  final bool Function()? hasSessionMessages;
  final void Function(AssistantStatus oldStatus, AssistantStatus newStatus, String hint)?
      onStatusChanged;
  final void Function(bool isInContinuous, String? reason)?
      onContinuousModeChanged;
  final void Function()? onNotify;
  final void Function()? onTranscriptsCleared;
  final Future<void> Function()? onSilenceTimeout;
  final Future<void> Function()? onLightRagIdleReset;

  // 状态字段
  AssistantStatus _status = AssistantStatus.idle;
  String _statusHint = '话筒未开启，点击右上角开启语音监听';
  bool _isInContinuousMode = false;
  bool _disposed = false;

  // 计时器
  Timer? _silenceTimer;
  Timer? _continuousTimer;
  Timer? _idleHygieneTimer;
  Timer? _lightRagIdleTimer;
  Timer? _unmatchedSpeechTimer;

  DialogueStateMachine({
    required this.settings,
    this.audioControlPort,
    this.ttsService,
    this.hasSessionMessages,
    this.onStatusChanged,
    this.onContinuousModeChanged,
    this.onNotify,
    this.onTranscriptsCleared,
    this.onSilenceTimeout,
    this.onLightRagIdleReset,
  });

  bool get isDisposed => _disposed;
  AssistantStatus get status => _status;
  bool get isInContinuousMode => _isInContinuousMode;

  /// 状态描述提示文案（考虑麦克风硬件开启状态修正）
  String get statusHint {
    if (_status == AssistantStatus.idle &&
        audioControlPort != null &&
        !audioControlPort!.isMicListening) {
      if (_statusHint.contains('唤醒') || _statusHint.contains('呼唤')) {
        return '话筒未开启，点击右上角开启语音监听';
      }
    }
    return _statusHint;
  }

  /// 状态描述短标签（待机 / 倾听 / 思考 / 播报 / 连续对话 / 失败）
  String get statusShortLabel {
    switch (_status) {
      case AssistantStatus.idle:
        if (_statusHint.contains('失败') ||
            _statusHint.contains('未成功') ||
            _statusHint.contains('异常')) {
          return '失败';
        }
        if (_isInContinuousMode) {
          return '连续对话';
        }
        return '待机';
      case AssistantStatus.listeningContent:
        return '倾听';
      case AssistantStatus.thinking:
        return '思考';
      case AssistantStatus.playing:
        return '播报';
    }
  }

  /// 当前配置下是否必须检测到开始词才激活交互
  bool get isWakeWordRequired {
    switch (settings.startWordMode) {
      case AppConstants.startWordModeDisabled:
        return false;
      case AppConstants.startWordModeEnabled:
        return true;
      case AppConstants.startWordModeAuto:
        return !_isInContinuousMode;
      default:
        return true;
    }
  }

  /// 跃迁到指定状态并更新提示文案
  void setStatus(AssistantStatus newStatus, [String? hint]) {
    final oldStatus = _status;
    _status = newStatus;

    scheduleLightRagIdleReset();
    scheduleIdleHygiene();

    if (newStatus != AssistantStatus.listeningContent) {
      _unmatchedSpeechTimer?.cancel();
      onTranscriptsCleared?.call();
    }

    if (hint != null) {
      _statusHint = hint;
    }

    onStatusChanged?.call(oldStatus, newStatus, _statusHint);
    onNotify?.call();
  }

  @visibleForTesting
  void setStatusForTesting(AssistantStatus status, String hint) {
    setStatus(status, hint);
  }

  /// 进入连续对话模式
  void enterContinuousMode() {
    if (settings.startWordMode != AppConstants.startWordModeAuto) return;
    _isInContinuousMode = true;
    resetContinuousTimer();
    onContinuousModeChanged?.call(true, null);
    onNotify?.call();
  }

  @visibleForTesting
  void enterContinuousModeForTesting() {
    enterContinuousMode();
  }

  /// 重置连续对话超时计时器
  void resetContinuousTimer() {
    if (_disposed) return;
    _continuousTimer?.cancel();
    if (settings.startWordMode != AppConstants.startWordModeAuto ||
        !_isInContinuousMode) {
      return;
    }
    final timeoutMinutes = settings.continuousModeTimeoutMinutes;
    if (timeoutMinutes <= 0) return;
    _continuousTimer = Timer(Duration(minutes: timeoutMinutes), () {
      unawaited(exitContinuousMode(
        byUser: false,
        reason: '长时间未对话，已退出连续对话，可说“${settings.startWord}”随时呼唤',
      ));
    });
  }

  /// 退出连续对话模式
  Future<void> exitContinuousMode({
    bool byUser = false,
    String? reason,
  }) async {
    _continuousTimer?.cancel();
    _continuousTimer = null;
    if (!_isInContinuousMode &&
        settings.startWordMode != AppConstants.startWordModeAuto) {
      return;
    }
    _isInContinuousMode = false;
    onContinuousModeChanged?.call(false, reason);
    onNotify?.call();

    if (byUser) {
      _silenceTimer?.cancel();
      _unmatchedSpeechTimer?.cancel();
      onTranscriptsCleared?.call();
      audioControlPort?.flushBuffers(cooldownMs: 300);
      setStatus(
        AssistantStatus.idle,
        '已退出连续对话，可说“${settings.startWord}”随时呼唤',
      );
      if (settings.enableTtsPlayback && ttsService != null) {
        await ttsService!.speakImmediate(AppConstants.exitContinuousPromptReply);
        audioControlPort?.flushBuffers(cooldownMs: 400);
      }
    } else {
      if (_status == AssistantStatus.idle) {
        setStatus(
          AssistantStatus.idle,
          reason ?? '长时间未对话，已退出连续对话，可说“${settings.startWord}”随时呼唤',
        );
      }
    }
  }

  /// 启动倾听态静音超时计时器
  void startSilenceTimer({
    int? overrideSeconds,
    Future<void> Function()? onTimeout,
  }) {
    _silenceTimer?.cancel();
    final timeout = overrideSeconds ?? settings.silenceTimeoutSeconds;
    _silenceTimer = Timer(Duration(seconds: timeout), () async {
      if (_status != AssistantStatus.listeningContent || _disposed) return;
      if (onTimeout != null) {
        await onTimeout();
      } else if (onSilenceTimeout != null) {
        await onSilenceTimeout!();
      } else {
        final exitHintWord = settings.exitContinuousWords.isNotEmpty
            ? settings.exitContinuousWords.first
            : '结束对话';
        final idleHint = _isInContinuousMode
            ? '连续对话中，可直接说话（说“$exitHintWord”退出）'
            : (isWakeWordRequired
                ? '待机中，可说“${settings.startWord}”随时呼唤'
                : '待机中，可随时直接说话交互');
        setStatus(AssistantStatus.idle, idleHint);
      }
    });
  }

  /// 重置倾听态静音超时计时器
  void resetSilenceTimer({Future<void> Function()? onTimeout}) {
    if (_status == AssistantStatus.listeningContent) {
      startSilenceTimer(onTimeout: onTimeout);
    }
  }

  /// 取消静音超时计时器
  void cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// 调度待机空闲 LightRAG 会话重置计时器
  void scheduleLightRagIdleReset() {
    _lightRagIdleTimer?.cancel();
    if (_disposed ||
        _status != AssistantStatus.idle ||
        !(hasSessionMessages?.call() ?? false)) {
      return;
    }
    _lightRagIdleTimer = Timer(
      const Duration(minutes: AppConstants.lightRagIdleMinutes),
      () {
        if (_disposed ||
            _status != AssistantStatus.idle ||
            !(hasSessionMessages?.call() ?? false)) {
          return;
        }
        unawaited(onLightRagIdleReset?.call());
      },
    );
  }

  /// 调度待机例行声学资源保洁周期计时器
  void scheduleIdleHygiene() {
    _idleHygieneTimer?.cancel();
    if (_disposed || _status != AssistantStatus.idle) {
      return;
    }
    _idleHygieneTimer = Timer.periodic(
      const Duration(minutes: 10),
      (timer) {
        if (_disposed || _status != AssistantStatus.idle) {
          timer.cancel();
          return;
        }
        audioControlPort?.performIdleHygiene();
      },
    );
  }

  /// 调度无唤醒杂音淡出清屏计时器
  void scheduleUnmatchedSpeechFade({
    required void Function() onFade,
    Duration duration = const Duration(seconds: 4),
  }) {
    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = Timer(duration, () {
      if (_status == AssistantStatus.idle) {
        onFade();
      }
    });
  }

  /// 取消无唤醒淡出计时器
  void cancelUnmatchedSpeechTimer() {
    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = null;
  }

  /// 取消所有活跃计时器
  void cancelAllTimers() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _continuousTimer?.cancel();
    _continuousTimer = null;
    _idleHygieneTimer?.cancel();
    _idleHygieneTimer = null;
    _lightRagIdleTimer?.cancel();
    _lightRagIdleTimer = null;
    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = null;
  }

  /// 增量更新设置
  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
    if (settings.startWordMode != AppConstants.startWordModeAuto) {
      unawaited(exitContinuousMode(byUser: false));
    }
  }

  /// 销毁状态机与释放内部所有计时器资源
  void dispose() {
    _disposed = true;
    _status = AssistantStatus.idle;
    cancelAllTimers();
  }
}
