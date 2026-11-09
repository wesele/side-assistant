import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/engine/coordinators/dialogue/support/local_playback_echo_guard.dart';
import 'package:side_assistant/core/engine/support/trigger_matcher.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/ports/tts_port.dart';

class _LocalTts extends NoopTtsPort {
  bool speaking = false;
  String recent = '';
  @override
  bool get isSpeaking => speaking;
  @override
  String get recentlySpokenText => recent;
}

void main() {
  late _LocalTts tts;
  late DateTime now;
  late LocalPlaybackEchoGuard guard;
  setUp(() {
    tts = _LocalTts();
    now = DateTime(2026, 11, 9);
    guard = LocalPlaybackEchoGuard(
      tts: tts,
      matcher: TriggerMatcher(settings: AppSettings()),
      now: () => now,
    );
  });

  test('local speech and tail send silence, then resume unchanged user audio',
      () {
    final audio = Float32List.fromList([0.12, -0.18, 0.04]);
    tts.speaking = true;
    expect(guard.guardUplink(audio), everyElement(0));
    expect(audio, [0.12, -0.18, 0.04].map((v) => closeTo(v, 0.00001)));
    tts.speaking = false;
    now = now.add(const Duration(milliseconds: 1400));
    expect(guard.guardUplink(audio), everyElement(0));
    now = now.add(const Duration(milliseconds: 101));
    expect(guard.guardUplink(audio), same(audio));
  });

  test('delayed reminder echo never opens a user/model turn', () {
    tts.recent = '一分钟闹钟提醒';
    expect(guard.acceptInput('一分钟闹钟提醒。', hasActiveTurn: false), isFalse);
    expect(guard.isEchoTurn, isTrue);
    expect(guard.consumeEchoTurn(), isTrue);
    expect(guard.isEchoTurn, isFalse);
  });

  test('echo during a pending tool does not discard the legitimate turn', () {
    tts.recent = '一分钟闹钟提醒';
    expect(guard.acceptInput('一分钟闹钟提醒。', hasActiveTurn: true), isFalse);
    expect(guard.isEchoTurn, isFalse);
  });

  test('real speech and mixed corrections remain user input', () {
    tts.recent = '一分钟闹钟提醒，现在停止';
    guard.acceptInput('一分钟闹钟提醒', hasActiveTurn: false);
    expect(guard.acceptInput('改成两分钟以后', hasActiveTurn: false), isTrue);
    expect(guard.isEchoTurn, isFalse);
    expect(guard.acceptInput('一分钟闹钟提醒，改成两分钟', hasActiveTurn: false), isTrue);
    expect(guard.acceptInput('停止', hasActiveTurn: false), isTrue);
  });
}
