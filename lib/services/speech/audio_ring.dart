import 'dart:math' as math;
import 'dart:typed_data';

/// 定长环形音频缓冲：容量一次性预分配，追加与截取都不再按当前长度重新分配。
///
/// 背景：旧实现每次 PCM 回调都 `Float32List(旧长度 + 新长度)` 再整段拷贝，环填满
/// 35 秒后每个回调要分配并拷贝约 4.5MB、产生同等垃圾。桌面端无感，移动端会持续
/// 触发 GC 卡顿，表现为丢帧（SurfaceView 掉帧）、AudioFlinger Overrun，以及 VAD
/// 切出残缺片段导致识别只剩零碎几个字。
class AudioRing {
  AudioRing(int capacity) : _buf = Float32List(capacity);

  final Float32List _buf;
  int _write = 0;
  int _count = 0;

  int get capacity => _buf.length;

  /// 当前有效样本数（<= [capacity]）。
  int get length => _count;

  void clear() {
    _write = 0;
    _count = 0;
  }

  /// 追加样本；超过容量时丢弃最旧的部分。
  void add(Float32List samples) {
    if (samples.isEmpty) return;
    final cap = _buf.length;
    if (samples.length >= cap) {
      _buf.setRange(0, cap, samples, samples.length - cap);
      _write = 0;
      _count = cap;
      return;
    }
    final first = math.min(samples.length, cap - _write);
    _buf.setRange(_write, _write + first, samples);
    if (first < samples.length) {
      _buf.setRange(0, samples.length - first, samples, first);
    }
    _write = (_write + samples.length) % cap;
    _count = math.min(cap, _count + samples.length);
  }

  /// 取逻辑区间 `[from, to)` 的副本（0 表示环里最旧的样本）。
  ///
  /// 越界会被裁剪到合法范围；`from >= to` 时返回空数组。
  Float32List slice(int from, int to) {
    final f = from.clamp(0, _count);
    final t = to.clamp(f, _count);
    final n = t - f;
    final out = Float32List(n);
    if (n == 0) return out;
    final cap = _buf.length;
    var phys = (_write - _count + f) % cap;
    if (phys < 0) phys += cap;
    final first = math.min(n, cap - phys);
    out.setRange(0, first, _buf, phys);
    if (first < n) {
      out.setRange(first, n, _buf, 0);
    }
    return out;
  }

  /// 整个有效区间的副本。
  Float32List snapshot() => slice(0, _count);
}
