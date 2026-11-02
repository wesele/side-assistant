import 'dart:io';

/// Linux 音频环境辅助工具类：
/// 确保 systemd 服务或 SSH 会话下能自动发现并注入 XDG_RUNTIME_DIR，
/// 从而无缝访问 PipeWire / PulseAudio 用户级守护进程。
class LinuxAudioEnvironment {
  LinuxAudioEnvironment._();

  static Map<String, String>? _cachedEnv;

  /// 构建包含 XDG_RUNTIME_DIR 的环境变量
  static Map<String, String> buildAudioEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if (!env.containsKey('XDG_RUNTIME_DIR') ||
        env['XDG_RUNTIME_DIR']!.isEmpty) {
      if (_cachedEnv != null && _cachedEnv!.containsKey('XDG_RUNTIME_DIR')) {
        env['XDG_RUNTIME_DIR'] = _cachedEnv!['XDG_RUNTIME_DIR']!;
        return env;
      }
      try {
        final res = Process.runSync('id', ['-u']);
        if (res.exitCode == 0) {
          final uid = res.stdout.toString().trim();
          final runDir = '/run/user/$uid';
          if (Directory(runDir).existsSync()) {
            env['XDG_RUNTIME_DIR'] = runDir;
            _cachedEnv = {'XDG_RUNTIME_DIR': runDir};
          }
        }
      } catch (_) {}
    }
    return env;
  }
}
