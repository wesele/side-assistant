/// 测试环境能力探测（区分"代码坏了"与"这台机器没这个能力"）。
///
/// 与 `model_assets.dart` 的分工：那个管「资产文件是不是真的」（LFS 指针问题），
/// 这个管「系统里有没有这个可执行程序 / 平台能力」。
///
/// 典型场景：Linux 上手动对讲录音依赖 `arecord`（alsa-utils），CI runner 默认
/// 不装；没有它时 `Process.start('arecord')` 会抛 `ProcessException`，测试挂掉
/// 但根因跟被测代码无关。此时应显式 skip，让报告出现 `~N` 而不是红色失败。
library;

import 'dart:io';

/// 判断系统里是否存在可执行程序 [name]（Windows 上走 `where`，其它走 `which`）。
///
/// 结果会缓存：同一进程内重复调用不会反复起子进程。
final Map<String, bool> _executableCache = <String, bool>{};

bool hasExecutable(String name) {
  final cached = _executableCache[name];
  if (cached != null) return cached;

  bool found;
  try {
    final probe = Platform.isWindows ? 'where' : 'which';
    final result = Process.runSync(probe, <String>[name]);
    found = result.exitCode == 0;
  } catch (_) {
    found = false;
  }
  _executableCache[name] = found;
  return found;
}

/// 缺少可执行程序时的统一跳过原因。
String missingExecutableReason(String name) =>
    '当前环境缺少可执行程序 `$name`（例如 CI 未安装 alsa-utils），无法验证该链路';

/// 直接传给 `test(..., skip: ...)` / `group(..., skip: ...)` 的便捷写法。
Object? skipUnlessExecutable(String name) =>
    hasExecutable(name) ? false : missingExecutableReason(name);

/// 仅在 Linux 上要求该可执行程序；Windows/macOS 走的是另一套录音后端，恒不跳过。
Object? skipUnlessLinuxExecutable(String name) =>
    Platform.isLinux && !hasExecutable(name)
        ? missingExecutableReason(name)
        : false;
