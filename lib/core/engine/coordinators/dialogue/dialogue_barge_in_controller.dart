import 'dart:async';

import '../../../models/app_settings.dart';
import '../../../platform/foundation_bridge.dart';
import '../../../ports/audio_stream_control_port.dart';
import '../../../ports/speaker_verification_port.dart';
import '../../../ports/trigger_matcher_port.dart';
import '../../../ports/tts_port.dart';
import '../../../../services/speech/transcript_processor.dart';

/// 播报即时打断处理决策类型
enum BargeInActionType {
  /// 未启用打断功能或文本为空
  ignoredDisabled,
  /// 判定为助手自身外放回声并已忽略
  ignoredEcho,
  /// 非打断关键词且未匹配开始词
  ignoredNotTrigger,
  /// 声纹鉴权未通过
  rejectedSpeaker,
  /// 纯停止词命中，已停止播报
  stopped,
  /// 命中新意图/唤醒词打断，转入倾听
  interrupted,
}

/// 播报即时打断仲裁结果数据
class BargeInResult {
  final BargeInActionType action;
  final String? remainingText;
  final bool isStartWordMatched;
  final String? rejectionReason;
  final bool exitedContinuous;

  const BargeInResult({
    required this.action,
    this.remainingText,
    this.isStartWordMatched = false,
    this.rejectionReason,
    this.exitedContinuous = false,
  });

  bool get isSuccessful =>
      action == BargeInActionType.stopped ||
      action == BargeInActionType.interrupted;
}

/// 播报即时打断与防回声协调控制器 (DialogueBargeInController)
///
/// 专职负责播报期间麦克风外放回声智能辨识剥离、即时打断关键词匹配、
/// 主人声纹打断鉴权，以及声学环形缓冲清空与 400ms 抑制冷却窗协同。
/// 纯 Dart 实现，零 `dart:ui` 或 `package:flutter` 依赖。
class DialogueBargeInController {
  AppSettings settings;
  final AudioStreamControlPort audioControlPort;
  final SpeakerVerificationPort speakerVerificationPort;
  final TtsPort ttsService;
  final TriggerMatcherPort triggerMatcher;

  // 协调回调
  final void Function(String reason)? onBargeInRejected;
  final Future<void> Function(String hint)? onStopPlaying;
  final Future<void> Function()? onExitContinuous;
  final Future<void> Function(String remainingText, bool isStartWordMatched)?
      onBargeInAccepted;

  DialogueBargeInController({
    required this.settings,
    required this.audioControlPort,
    required this.speakerVerificationPort,
    required this.ttsService,
    required this.triggerMatcher,
    this.onBargeInRejected,
    this.onStopPlaying,
    this.onExitContinuous,
    this.onBargeInAccepted,
  });

  /// 检查识别文本是否由 TTS 最近外放内容经麦克风拾音引起
  bool looksLikeAssistantEcho(String recognized) {
    return TranscriptProcessor.looksLikeAssistantEcho(
      recognized: recognized,
      recentlySpokenText: ttsService.recentlySpokenText,
      triggerMatcher: triggerMatcher,
    );
  }

  /// 从可能夹带外放尾音的识别文本中剥离回声，保留用户说话残片
  String stripAssistantEcho(String recognized) {
    return TranscriptProcessor.stripAssistantEcho(
      recognized: recognized,
      recentlySpokenText: ttsService.recentlySpokenText,
      triggerMatcher: triggerMatcher,
    );
  }

  /// 处理播报期间收到的原始转写流（先剥离回声，残余文本转入打断判决）
  Future<BargeInResult> handlePlayingText(
    String rawText, {
    bool isInContinuousMode = false,
  }) async {
    if (!settings.enableBargeIn) {
      return const BargeInResult(action: BargeInActionType.ignoredDisabled);
    }

    final residual = stripAssistantEcho(rawText);
    if (residual.isEmpty) {
      debugPrint('[DialogueBargeInController] 播报期间已丢弃外放回声: "$rawText"');
      return const BargeInResult(action: BargeInActionType.ignoredEcho);
    }

    return handlePlayingBargeIn(residual, isInContinuousMode: isInContinuousMode);
  }

  /// 播报期间即时打断核心判定与声学缓冲冷却协同
  Future<BargeInResult> handlePlayingBargeIn(
    String text, {
    bool isInContinuousMode = false,
  }) async {
    if (!settings.enableBargeIn) {
      return const BargeInResult(action: BargeInActionType.ignoredDisabled);
    }

    final cleanRecognized = text.trim();
    if (cleanRecognized.isEmpty) {
      return const BargeInResult(action: BargeInActionType.ignoredDisabled);
    }

    final isPureStop = cleanRecognized == '停止' ||
        cleanRecognized == '暂停' ||
        cleanRecognized == '闭嘴' ||
        cleanRecognized == '别说了' ||
        cleanRecognized == '退下';

    final hasBargeInKeyword = cleanRecognized.contains('停止') ||
        cleanRecognized.contains('暂停') ||
        cleanRecognized.contains('别说了') ||
        cleanRecognized.contains('闭嘴') ||
        cleanRecognized.contains('别读了') ||
        cleanRecognized.contains('退下') ||
        cleanRecognized.contains('打断') ||
        cleanRecognized.contains('等等') ||
        cleanRecognized.contains('等一下');

    final startMatch = hasBargeInKeyword
        ? TriggerMatchResult.none()
        : await triggerMatcher.checkStartWord(cleanRecognized);

    if (!hasBargeInKeyword && !startMatch.isMatched) {
      debugPrint(
        '[DialogueBargeInController] 播报期间忽略非打断指令/外放回采: "$cleanRecognized"',
      );
      return const BargeInResult(action: BargeInActionType.ignoredNotTrigger);
    }

    // 声纹身份核验门禁
    String? rejectedReason;
    final isOwnerVerified = speakerVerificationPort.verifyOwnerSpeaker(
      contextHint: '打断播报',
      onRejected: (reason) {
        rejectedReason = reason;
        onBargeInRejected?.call(reason);
      },
    );

    if (!isOwnerVerified) {
      return BargeInResult(
        action: BargeInActionType.rejectedSpeaker,
        rejectionReason: rejectedReason,
      );
    }

    debugPrint(
      '[DialogueBargeInController] 播报期间触发打断: text="$cleanRecognized", isStop=$isPureStop, startMatch=${startMatch.matchedText}',
    );

    // 立即终止 TTS 播报并清空麦克风缓冲区，设立 400ms 声学冷却静音窗
    await ttsService.stop();
    audioControlPort.flushBuffers(cooldownMs: 400);

    // 纯停止词处理
    if (isPureStop) {
      if (isInContinuousMode &&
          await triggerMatcher.checkExitContinuousWord(cleanRecognized)) {
        if (onExitContinuous != null) {
          await onExitContinuous!();
        }
        return const BargeInResult(
          action: BargeInActionType.stopped,
          exitedContinuous: true,
        );
      }

      if (onStopPlaying != null) {
        await onStopPlaying!('已停止朗读，返回待机');
      }
      return const BargeInResult(
        action: BargeInActionType.stopped,
        exitedContinuous: false,
      );
    }

    // 携带新指令或唤醒词打断转入倾听
    final remaining = startMatch.isMatched
        ? TranscriptProcessor.extractRemainingAfterStart(
            cleanRecognized,
            startMatch,
          ).trim()
        : cleanRecognized;

    if (onBargeInAccepted != null) {
      await onBargeInAccepted!(remaining, startMatch.isMatched);
    }

    return BargeInResult(
      action: BargeInActionType.interrupted,
      remainingText: remaining,
      isStartWordMatched: startMatch.isMatched,
    );
  }

  /// 增量更新设置
  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
  }

  void dispose() {}
}
