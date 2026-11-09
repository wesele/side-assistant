import '../../../../constants/app_constants.dart';

/// Gemini Live 工具执行进度心跳文案构建工具
class GeminiLiveToolProgressHelper {
  static ({String display, String spoken}) buildProgressText({
    required String toolName,
    required String query,
    required int tick,
    required int elapsedSec,
    required String codeAgentProvider,
  }) {
    final q = query.trim();
    if (toolName == 'invoke_opencode') {
      final agentName =
          codeAgentProvider == AppConstants.codeAgentProviderHermes
              ? 'Hermes'
              : 'OpenCode';
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
}
