import 'dart:async';

import '../../../../constants/app_constants.dart';

/// Gemini Live 工具执行状态与进度心跳文案构建工具
class GeminiLiveToolProgressHelper {
  static String resolveAgentName(String codeAgentProvider) =>
      codeAgentProvider == AppConstants.codeAgentProviderHermes
          ? 'Hermes'
          : 'OpenCode';

  static String buildCallStatusDisplay({
    required String toolName,
    required String query,
    required String codeAgentProvider,
  }) {
    final q = query.trim();
    final agentName = resolveAgentName(codeAgentProvider);
    return switch (toolName) {
      'capture_photo' => '正在调用相机拍照...',
      'web_search' => q.isNotEmpty ? '正在联网搜索：$q...' : '正在联网搜索...',
      'call_custom_tool' => q.isNotEmpty ? '正在调用工具：$q...' : '正在执行扩展工具...',
      'invoke_opencode' =>
        q.isNotEmpty ? '正在调用 $agentName 构建工具：$q...' : '正在调用 $agentName 构建工具...',
      _ => q.isNotEmpty ? '正在检索：$q...' : '正在查询...',
    };
  }

  static String buildPreCallSpoken({
    required String toolName,
    required String query,
    required String codeAgentProvider,
  }) {
    final q = query.trim();
    if (toolName == 'invoke_opencode') {
      final agentName = resolveAgentName(codeAgentProvider);
      return q.isNotEmpty
          ? '好的，我先用 $agentName 帮你构建并执行 $q，可能需要一点时间，请稍候。'
          : '好的，我先用 $agentName 帮你构建工具，可能需要一点时间，请稍候。';
    }
    return q.isNotEmpty ? '好的，我这就调用 $q 工具帮你处理，请稍等。' : '好的，我这就调用工具帮你处理，请稍等。';
  }

  static ({String display, String spoken}) buildProgressText({
    required String toolName,
    required String query,
    required int tick,
    required int elapsedSec,
    required String codeAgentProvider,
  }) {
    final q = query.trim();
    if (toolName == 'invoke_opencode') {
      final agentName = resolveAgentName(codeAgentProvider);
      final target = q.isNotEmpty ? '「$q」' : '工具';
      switch ((tick - 1) % 3) {
        case 0:
          return (
            display:
                '正在通过 $agentName 编写并调试$target，已经进行了约 $elapsedSec 秒，请再稍等一下...',
            spoken: q.isNotEmpty
                ? '还在帮你构建 $q 工具，稍微有点复杂，请再稍等一下哦。'
                : '还在帮你构建工具，稍微有点复杂，请再稍等一下哦。',
          );
        case 1:
          return (
            display: '仍在努力构建$target中（已耗时约 $elapsedSec 秒），马上就好...',
            spoken: '工具还在编写和测试中，马上就好，请稍候。',
          );
        default:
          return (
            display: '还在继续优化并执行$target（已耗时约 $elapsedSec 秒），请稍候...',
            spoken: '还在进行最后的调试和执行，请再耐心等待一会儿。',
          );
      }
    } else {
      final target = q.isNotEmpty ? '「$q」' : '扩展工具';
      switch ((tick - 1) % 3) {
        case 0:
          return (
            display: '正在执行$target，已经进行了约 $elapsedSec 秒，请再稍等一下...',
            spoken: q.isNotEmpty
                ? '还在帮你处理 $q，稍微有点耗时，请再稍等一下哦。'
                : '还在帮你处理任务，稍微有点耗时，请再稍等一下哦。',
          );
        case 1:
          return (
            display: '仍在处理$target中（已耗时约 $elapsedSec 秒），马上就好...',
            spoken: '后台还在处理中，马上就好，请稍候。',
          );
        default:
          return (
            display: '还在继续执行$target（已耗时约 $elapsedSec 秒），请稍候...',
            spoken: '还在继续执行，请再耐心等待一会儿。',
          );
      }
    }
  }

  static Timer startProgressTimer({
    required Duration interval,
    required String toolName,
    required String query,
    required String Function() getCodeAgentProvider,
    required bool Function() shouldSpeak,
    required void Function(String display) onPublish,
    required void Function(String spoken) onSpeak,
  }) {
    var tick = 0;
    final watch = Stopwatch()..start();
    return Timer.periodic(interval, (_) {
      tick++;
      final progress = buildProgressText(
        toolName: toolName,
        query: query,
        tick: tick,
        elapsedSec: watch.elapsed.inSeconds,
        codeAgentProvider: getCodeAgentProvider(),
      );
      onPublish(progress.display);
      if (shouldSpeak()) onSpeak(progress.spoken);
    });
  }
}
