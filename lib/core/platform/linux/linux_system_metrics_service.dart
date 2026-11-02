import 'dart:io';

/// Linux 系统性能指标服务：
/// 基于读取 /proc/stat 统计 CPU 时间切片，计算瞬时与平滑 CPU 占用率，
/// 无子进程调用开销，具备 600ms 采样防抖与单测重置能力。
class LinuxSystemMetricsService {
  LinuxSystemMetricsService._();

  static int _prevCpuTotalTime = 0;
  static int _prevCpuActiveTime = 0;
  static DateTime _lastCpuSampleTime = DateTime.fromMillisecondsSinceEpoch(0);
  static double _lastCpuUsagePercent = 0.0;

  /// 从 /proc/stat 内容解析瞬时 CPU 时间计数 (active, total)
  static (int active, int total)? parseProcStatCpuCounters(String content) {
    try {
      final lines = content.split('\n');
      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.startsWith('cpu ') || line.startsWith('cpu\t')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 5) {
            final user = int.tryParse(parts[1]) ?? 0;
            final nice = int.tryParse(parts[2]) ?? 0;
            final system = int.tryParse(parts[3]) ?? 0;
            final idle = int.tryParse(parts[4]) ?? 0;
            final iowait = parts.length > 5 ? (int.tryParse(parts[5]) ?? 0) : 0;
            final irq = parts.length > 6 ? (int.tryParse(parts[6]) ?? 0) : 0;
            final softirq =
                parts.length > 7 ? (int.tryParse(parts[7]) ?? 0) : 0;
            final steal = parts.length > 8 ? (int.tryParse(parts[8]) ?? 0) : 0;

            final active = user + nice + system + irq + softirq + steal;
            final total = active + idle + iowait;
            return (active, total);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 重置 CPU 计算计数器（主要用于单元测试隔离）
  static void resetCpuUsageCountersForTest() {
    _prevCpuTotalTime = 0;
    _prevCpuActiveTime = 0;
    _lastCpuSampleTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastCpuUsagePercent = 0.0;
  }

  /// 获取 Linux 系统当前实时的 CPU 占用百分比 (0.0 - 100.0)
  /// 基于读取 /proc/stat 计算，零子进程开销，附带 600ms 采样防抖
  static double getCpuUsagePercent({String procStatPath = '/proc/stat'}) {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastCpuSampleTime).inMilliseconds;
    if (_prevCpuTotalTime > 0 && elapsedMs < 600) {
      return _lastCpuUsagePercent;
    }

    try {
      final statFile = File(procStatPath);
      if (!statFile.existsSync()) {
        return _lastCpuUsagePercent;
      }

      final content = statFile.readAsStringSync();
      final counters = parseProcStatCpuCounters(content);
      if (counters == null) return _lastCpuUsagePercent;

      final (active, total) = counters;

      if (_prevCpuTotalTime == 0) {
        _prevCpuTotalTime = total;
        _prevCpuActiveTime = active;
        _lastCpuSampleTime = now;
        _lastCpuUsagePercent = 0.0;
        return 0.0;
      }

      final deltaTotal = total - _prevCpuTotalTime;
      final deltaActive = active - _prevCpuActiveTime;

      _prevCpuTotalTime = total;
      _prevCpuActiveTime = active;
      _lastCpuSampleTime = now;

      if (deltaTotal > 0 && deltaActive >= 0) {
        _lastCpuUsagePercent =
            ((deltaActive / deltaTotal) * 100.0).clamp(0.0, 100.0);
      }
    } catch (_) {}

    return _lastCpuUsagePercent;
  }
}
