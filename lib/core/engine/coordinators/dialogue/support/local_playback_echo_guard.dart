import 'dart:typed_data';

import '../../../../ports/trigger_matcher_port.dart';
import '../../../../ports/tts_port.dart';
import '../../../support/transcript_processor.dart';

/// Local reminders/status speech do not use Gemini's native PCM player.
/// Keep their audio out of the uplink and reject delayed pure echo transcripts
/// before they create user messages or split a deferred tool turn.
class LocalPlaybackEchoGuard {
  LocalPlaybackEchoGuard({
    required this.tts,
    required this.matcher,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final TtsPort tts;
  final TriggerMatcherPort matcher;
  final DateTime Function() _now;
  DateTime _tailUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool isEchoTurn = false;

  Float32List guardUplink(Float32List samples) {
    final now = _now();
    if (tts.isSpeaking) {
      _tailUntil = now.add(const Duration(milliseconds: 1500));
    }
    return now.isBefore(_tailUntil) ? Float32List(samples.length) : samples;
  }

  bool acceptInput(String text, {required bool hasActiveTurn}) {
    final normalized = matcher.stripPunctuation(text, all: true);
    final echo = normalized.length >= 3 &&
        tts.recentlySpokenText.isNotEmpty &&
        TranscriptProcessor.stripAssistantEcho(
          recognized: text,
          recentlySpokenText: tts.recentlySpokenText,
          triggerMatcher: matcher,
        ).isEmpty;
    if (echo) {
      // Preserve the legitimate response to an existing tool request.
      if (!hasActiveTurn) isEchoTurn = true;
      return false;
    }
    isEchoTurn = false;
    return true;
  }

  bool consumeEchoTurn() {
    final ignored = isEchoTurn;
    isEchoTurn = false;
    return ignored;
  }
}
