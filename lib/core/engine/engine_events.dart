import '../models/app_settings.dart';
import '../models/assistant_status.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// 音频电平与 VAD 实时状态指标
class AudioLevelMetrics {
  final double level;
  final double dbfs;
  final bool vadDetected;

  const AudioLevelMetrics({
    this.level = 0.0,
    this.dbfs = -60.0,
    this.vadDetected = false,
  });

  @override
  String toString() =>
      'AudioLevelMetrics(level: ${level.toStringAsFixed(2)}, dbfs: ${dbfs.toStringAsFixed(1)}, vad: $vadDetected)';
}

/// 纯 Dart 引擎事件基类
sealed class AssistantEngineEvent {
  final DateTime timestamp;
  AssistantEngineEvent({DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

/// 状态机状态变迁事件（待机、倾听、思考、播报）
class StatusChangedEvent extends AssistantEngineEvent {
  final AssistantStatus oldStatus;
  final AssistantStatus newStatus;
  final String hint;

  AssistantStatus get previousStatus => oldStatus;
  AssistantStatus get status => newStatus;
  String get statusHint => hint;

  StatusChangedEvent(
    this.oldStatus,
    this.newStatus, {
    String? hint,
    super.timestamp,
  }) : hint = hint ?? '';

  @override
  String toString() =>
      'StatusChangedEvent($oldStatus -> $newStatus, hint: "$hint")';
}

/// 识别文字流更新事件（实时中间字稿、最终识别文本、唤醒标记）
class TranscriptUpdatedEvent extends AssistantEngineEvent {
  final String live;
  final String display;
  final String lastRecognized;
  final bool isWakeWordMatched;
  final bool isFinal;

  String get liveTranscript => live;
  String get displayTranscript => display;
  String get lastRecognizedSpeech => lastRecognized;

  TranscriptUpdatedEvent({
    String? live,
    String? display,
    String? lastRecognized,
    this.isWakeWordMatched = false,
    this.isFinal = false,
    super.timestamp,
  })  : live = live ?? '',
        display = display ?? '',
        lastRecognized = lastRecognized ?? '';

  @override
  String toString() =>
      'TranscriptUpdatedEvent(live: "$live", display: "$display", last: "$lastRecognized", matched: $isWakeWordMatched, isFinal: $isFinal)';
}

/// 音频与 VAD 实时指标事件（电平、dBFS、VAD 激活标志）
class MetricsUpdatedEvent extends AssistantEngineEvent {
  final AudioLevelMetrics metrics;

  double get level => metrics.level;
  double get dbfs => metrics.dbfs;
  bool get vadDetected => metrics.vadDetected;

  MetricsUpdatedEvent(this.metrics, {super.timestamp});

  MetricsUpdatedEvent.fromValues({
    required double level,
    required double dbfs,
    required bool vadDetected,
    super.timestamp,
  }) : metrics = AudioLevelMetrics(
          level: level,
          dbfs: dbfs,
          vadDetected: vadDetected,
        );

  @override
  String toString() => 'MetricsUpdatedEvent($metrics)';
}

/// 消息列表追加事件（新用户提问或新助手占位消息生成）
class MessageAppendedEvent extends AssistantEngineEvent {
  final ChatMessage message;
  final int index;
  final String sessionId;

  MessageAppendedEvent(
    this.message, {
    this.index = -1,
    this.sessionId = '',
    super.timestamp,
  });

  @override
  String toString() =>
      'MessageAppendedEvent(#$index [${message.role}] in $sessionId)';
}

/// 消息内容更新事件（大模型流式回复 chunk 到达，更新助手消息内容或照片路径）
class MessageUpdatedEvent extends AssistantEngineEvent {
  final ChatMessage message;
  final String messageId;
  final String content;
  final String? imagePath;
  final String sessionId;

  MessageUpdatedEvent(
    this.message, {
    String? messageId,
    String? content,
    this.imagePath,
    this.sessionId = '',
    super.timestamp,
  })  : messageId = messageId ?? message.id,
        content = content ?? message.content;

  @override
  String toString() =>
      'MessageUpdatedEvent(msgId: $messageId, len: ${content.length})';
}

/// 连续对话模式状态变更事件
class ContinuousModeChangedEvent extends AssistantEngineEvent {
  final bool enabled;
  final String? reason;

  bool get isInContinuousMode => enabled;

  ContinuousModeChangedEvent(
    this.enabled, {
    this.reason,
    super.timestamp,
  });

  @override
  String toString() =>
      'ContinuousModeChangedEvent(enabled: $enabled, reason: $reason)';
}

/// 会话变更事件（切换会话、创建新会话、重命名、删除或清空）
class SessionChangedEvent extends AssistantEngineEvent {
  final String sessionId;
  final List<ChatSession>? sessions;
  final String action;

  String get currentSessionId => sessionId;

  SessionChangedEvent(
    this.sessionId, {
    this.sessions,
    this.action = 'switched',
    super.timestamp,
  });

  @override
  String toString() =>
      'SessionChangedEvent(action: $action, currentId: $sessionId, total: ${sessions?.length ?? 0})';
}

/// 麦克风录音测试历史与识别结果更新事件
class MicTestUpdatedEvent extends AssistantEngineEvent {
  final String text;
  final List<dynamic> history;
  final int durationMs;
  final String engine;

  MicTestUpdatedEvent(
    this.text,
    this.history, {
    this.durationMs = 0,
    this.engine = '',
    super.timestamp,
  });

  @override
  String toString() =>
      'MicTestUpdatedEvent(text: "$text", historyCount: ${history.length})';
}

/// 麦克风监听开关或硬件输入设备状态变更
class MicListeningChangedEvent extends AssistantEngineEvent {
  final bool isListening;
  final bool isManualRecording;
  final String activeDeviceLabel;

  MicListeningChangedEvent(
    this.isListening, {
    this.isManualRecording = false,
    this.activeDeviceLabel = '',
    super.timestamp,
  });

  @override
  String toString() =>
      'MicListeningChangedEvent(listening: $isListening, manual: $isManualRecording, device: "$activeDeviceLabel")';
}

/// 引擎设置变更事件
class SettingsUpdatedEvent extends AssistantEngineEvent {
  final AppSettings settings;

  SettingsUpdatedEvent(this.settings, {super.timestamp});

  @override
  String toString() => 'SettingsUpdatedEvent()';
}

/// 提示音播放事件（例如激活唤醒轻滴声、快门声）
class SoundEffectTriggeredEvent extends AssistantEngineEvent {
  final String soundType; // 'acknowledge_beep', 'shutter'

  SoundEffectTriggeredEvent(this.soundType, {super.timestamp});

  @override
  String toString() => 'SoundEffectTriggeredEvent(type: $soundType)';
}

/// 引擎内部错误或异常警告事件
class EngineErrorEvent extends AssistantEngineEvent {
  final String error;
  final Object? errorObject;
  final StackTrace? stackTrace;

  String get message => error;

  EngineErrorEvent(
    this.error, {
    this.errorObject,
    this.stackTrace,
    super.timestamp,
  });

  @override
  String toString() => 'EngineErrorEvent(msg: "$error", error: $errorObject)';
}
