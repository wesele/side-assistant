import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/speech/audio_ring.dart';

Float32List _ramp(int from, int count) =>
    Float32List.fromList(List<double>.generate(count, (i) => (from + i).toDouble()));

void main() {
  group('AudioRing', () {
    test('未填满时按顺序返回全部有效样本', () {
      final ring = AudioRing(16);
      ring.add(_ramp(0, 5));
      ring.add(_ramp(5, 4));

      expect(ring.length, 9);
      expect(ring.snapshot(), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('超过容量时丢弃最旧样本并正确回绕', () {
      final ring = AudioRing(8);
      ring.add(_ramp(0, 6));
      ring.add(_ramp(6, 6)); // 总 12，只应保留最后 8 个：4..11

      expect(ring.length, 8);
      expect(ring.snapshot(), [4, 5, 6, 7, 8, 9, 10, 11]);
    });

    test('单次追加超过容量时只保留尾部', () {
      final ring = AudioRing(4);
      ring.add(_ramp(0, 10));

      expect(ring.length, 4);
      expect(ring.snapshot(), [6, 7, 8, 9]);
    });

    test('slice 支持环回绕的跨段区间', () {
      final ring = AudioRing(8);
      ring.add(_ramp(0, 6));
      ring.add(_ramp(6, 6)); // 内容 4..11，逻辑 0 => 4

      expect(ring.slice(0, 3), [4, 5, 6]);
      expect(ring.slice(5, 8), [9, 10, 11]);
      expect(ring.slice(2, 6), [6, 7, 8, 9]);
    });

    test('slice 越界被裁剪且非法区间返回空', () {
      final ring = AudioRing(8);
      ring.add(_ramp(0, 3));

      expect(ring.slice(-5, 2), [0, 1]);
      expect(ring.slice(1, 999), [1, 2]);
      expect(ring.slice(2, 1), isEmpty);
      expect(ring.slice(5, 8), isEmpty);
    });

    test('clear 后重新计数并覆盖旧内容', () {
      final ring = AudioRing(8);
      ring.add(_ramp(0, 8));
      ring.clear();
      expect(ring.length, 0);
      expect(ring.snapshot(), isEmpty);

      ring.add(_ramp(20, 3));
      expect(ring.snapshot(), [20, 21, 22]);
    });

    test('多次小块追加与一次大块追加结果一致', () {
      final chunked = AudioRing(32);
      final whole = AudioRing(32);
      final source = _ramp(0, 50);

      for (var i = 0; i < source.length; i += 3) {
        final end = i + 3 < source.length ? i + 3 : source.length;
        chunked.add(Float32List.sublistView(source, i, end));
      }
      whole.add(source);

      expect(chunked.snapshot(), whole.snapshot());
    });
  });
}
