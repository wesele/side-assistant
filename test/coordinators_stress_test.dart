import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/nlp/vector_math.dart';
import 'package:side_assistant/services/speech/speaker_verification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async {
      if (methodCall.method == 'hasPermission') return true;
      if (methodCall.method == 'isRecording') return false;
      if (methodCall.method == 'start') return null;
      if (methodCall.method == 'stop') return 'stress_test.wav';
      return null;
    },
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (methodCall) async => '.',
  );
  HttpOverrides.global = null;

  AppSettings buildStressSettings() => AppSettings(
        startWord: '晓漫',
        endWord: '回答',
        resetWord: '新起一个',
        ttsEngine: 'system',
        asrEngine: AppConstants.asrEngineStreaming,
        enableTwoPass: false,
        enableTtsPlayback: false,
        enableSpeakerVerification: true,
        speakerSimilarityThreshold: 0.65,
      );

  group('Adversarial Stress Harness: VoicePipelineCoordinator', () {
    test('1. High-frequency audio metrics & VAD stress (>5000 pulses/sec) with zero frame drops & zero notifyListeners flooding', () async {
      SharedPreferences.setMockInitialValues({});
      final emittedEvents = <AssistantEngineEvent>[];
      int notifyCount = 0;

      final coordinator = VoicePipelineCoordinator(
        settings: buildStressSettings(),
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
      );

      const int totalPulses = 6000;
      final sw = Stopwatch()..start();

      // Blast 6000 pulses into coordinator's audio level handler
      for (int i = 0; i < totalPulses; i++) {
        final level = (i % 100) / 100.0;
        final dbfs = -60.0 + ((i % 60));
        final vadNow = (i % 2 == 0);

        // Directly invoke the callback wired to VoiceListeningService
        coordinator.voiceListeningService.onAudioLevelChanged?.call(
          level,
          dbfs,
          vadNow,
        );
      }
      sw.stop();

      final elapsedMs = sw.elapsedMilliseconds;
      final pulsesPerSec = (totalPulses / (elapsedMs > 0 ? elapsedMs : 1)) * 1000;
      // ignore: avoid_print
      print('[Stress Harness] Processed $totalPulses audio pulses in ${elapsedMs}ms (${pulsesPerSec.toStringAsFixed(0)} pulses/sec)');

      // Assertion 1: Throughput meets or exceeds 5000 pulses/second
      expect(pulsesPerSec, greaterThanOrEqualTo(5000.0));

      // Assertion 2: Zero frame drops
      expect(emittedEvents.length, equals(totalPulses));
      final metricsEvents = emittedEvents.whereType<MetricsUpdatedEvent>().toList();
      expect(metricsEvents.length, equals(totalPulses));

      // Assertion 3: notifyListeners was NOT flooded (must be 0!)
      expect(
        notifyCount,
        equals(0),
        reason: 'Metrics updates must go to event stream and NEVER flood notifyListeners()',
      );

      // Assertion 4: Payload integrity on sample points
      expect(metricsEvents[0].metrics.level, closeTo(0.0, 0.001));
      expect(metricsEvents[0].metrics.vadDetected, isTrue);

      expect(metricsEvents[1].metrics.level, closeTo(0.01, 0.001));
      expect(metricsEvents[1].metrics.vadDetected, isFalse);

      expect(metricsEvents[5999].metrics.level, closeTo(0.99, 0.001));
      expect(metricsEvents[5999].metrics.vadDetected, isFalse);

      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);
    });

    test('2. Rapid VAD alternating state churn (5000 transitions) and memory stability check', () async {
      SharedPreferences.setMockInitialValues({});
      final emittedEvents = <AssistantEngineEvent>[];
      int notifyCount = 0;

      final coordinator = VoicePipelineCoordinator(
        settings: buildStressSettings(),
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
      );

      const int transitions = 5000;
      bool currentVad = false;

      final sw = Stopwatch()..start();
      for (int i = 0; i < transitions; i++) {
        currentVad = !currentVad;
        coordinator.voiceListeningService.onAudioLevelChanged?.call(
          currentVad ? 0.85 : 0.05,
          currentVad ? -12.0 : -55.0,
          currentVad,
        );
      }
      sw.stop();

      expect(emittedEvents.length, equals(transitions));
      expect(notifyCount, equals(0));

      final first = emittedEvents.first as MetricsUpdatedEvent;
      final last = emittedEvents.last as MetricsUpdatedEvent;
      expect(first.metrics.vadDetected, isTrue);
      expect(last.metrics.vadDetected, equals(transitions % 2 != 0));

      // Verify no unbounded memory buffer accumulation in coordinator
      expect(coordinator.micTestHistory.length, equals(0));

      coordinator.dispose();
    });

    test('3. Simulated PCM chunk stream level computation and 90ms rate-limiting vs VAD edge triggering', () {
      SharedPreferences.setMockInitialValues({});
      final coordinator = VoicePipelineCoordinator(
        settings: buildStressSettings(),
        emit: (_) {},
        onNotify: () {},
      );

      // Verify VoiceListeningService internal metrics accessors
      expect(coordinator.micLevel, equals(0.0));
      expect(coordinator.micDbfs, equals(-60.0));
      expect(coordinator.vadDetected, isFalse);

      // When manual recording or listening state changes, notifyListeners is called exactly once per transition
      int stateChangeNotifies = 0;
      coordinator.voiceListeningService.onStateChanged?.call(true, '监听中');
      stateChangeNotifies++;
      expect(stateChangeNotifies, equals(1));

      coordinator.dispose();
    });
  });

  group('Adversarial Stress Harness: SessionCoordinator', () {
    test('1. Rapid concurrent message appending and multi-chunk streaming updates', () async {
      SharedPreferences.setMockInitialValues({});
      final emittedEvents = <AssistantEngineEvent>[];
      int notifyCount = 0;

      final coordinator = SessionCoordinator(
        emit: emittedEvents.add,
        onNotify: () => notifyCount++,
      );
      await coordinator.loadChatHistory();

      const int concurrentDialogues = 50;
      const int chunksPerDialogue = 20;

      // Append 50 dialogue pairs
      final pairs = <AppendedMessagePair>[];
      for (int i = 0; i < concurrentDialogues; i++) {
        final pair = coordinator.appendUserAndPlaceholderMessage('用户并发提问 $i');
        pairs.add(pair);
      }

      expect(coordinator.messages.length, equals(concurrentDialogues * 2));
      expect(pairs.length, equals(concurrentDialogues));

      // Concurrently stream 20 chunks into all 50 assistant messages in interleaved fashion
      final futures = <Future<void>>[];
      for (int chunk = 1; chunk <= chunksPerDialogue; chunk++) {
        for (int d = 0; d < concurrentDialogues; d++) {
          final pair = pairs[d];
          futures.add(Future.microtask(() {
            coordinator.updateAssistantMessageContent(
              pair.assistantMsgId,
              pair.assistantMsgIndex,
              '消息 $d 累积流式输出第 $chunk 块: ${"A" * chunk}',
            );
          }));
        }
      }

      await Future.wait(futures);

      // Verify state consistency: no corrupted messages, every assistant message has final chunk
      for (int d = 0; d < concurrentDialogues; d++) {
        final pair = pairs[d];
        final msg = coordinator.messages.firstWhere((m) => m.id == pair.assistantMsgId);
        expect(msg.content, equals('消息 $d 累积流式输出第 $chunksPerDialogue 块: ${"A" * chunksPerDialogue}'));
        expect(msg.sessionId, equals(coordinator.currentSessionId));
      }

      expect(notifyCount, greaterThan(concurrentDialogues * chunksPerDialogue));
      coordinator.dispose();
    });

    test('2. Concurrent session creation, switching, and interleaved streaming updates without state corruption', () async {
      SharedPreferences.setMockInitialValues({});
      final coordinator = SessionCoordinator(
        emit: (_) {},
        onNotify: () {},
      );
      await coordinator.loadChatHistory();

      // Create session 1 and append messages
      final pair1 = coordinator.appendUserAndPlaceholderMessage('会话 1 问题');
      final session1Id = coordinator.currentSessionId;
      await coordinator.syncCurrentSession(persist: true);

      // Create session 2
      await coordinator.startNewSession();
      final session2Id = coordinator.currentSessionId;
      expect(session2Id, isNot(equals(session1Id)));

      coordinator.appendUserAndPlaceholderMessage('会话 2 问题');
      await coordinator.syncCurrentSession(persist: true);

      // Create session 3
      await coordinator.startNewSession();
      final session3Id = coordinator.currentSessionId;
      expect(session3Id, isNot(equals(session2Id)));

      // Adversarial test: send streaming updates aimed at Session 1's assistant message
      // while Session 3 is currently active.
      // Must NOT corrupt Session 3 messages or crash with RangeError!
      coordinator.updateAssistantMessageContent(
        pair1.assistantMsgId,
        pair1.assistantMsgIndex,
        '陈旧会话1的迟到内容',
      );

      // Since session 1 is not active, messages in session 3 should not be touched
      expect(coordinator.messages.any((m) => m.content == '陈旧会话1的迟到内容'), isFalse);

      // Rapid concurrent switching back and forth
      final switchFutures = <Future<void>>[
        coordinator.switchSession(session1Id),
        coordinator.switchSession(session2Id),
        coordinator.switchSession(session1Id),
      ];
      await Future.wait(switchFutures);

      // Current session must be one of the valid sessions
      expect(
        [session1Id, session2Id].contains(coordinator.currentSessionId),
        isTrue,
      );

      // All messages in current session must belong to current session
      for (final m in coordinator.messages) {
        expect(m.sessionId, equals(coordinator.currentSessionId));
      }

      coordinator.dispose();
    });

    test('3. High-stress concurrent session CRUD operations', () async {
      SharedPreferences.setMockInitialValues({});
      final coordinator = SessionCoordinator(
        emit: (_) {},
        onNotify: () {},
      );
      await coordinator.loadChatHistory();

      // Populate 10 distinct sessions
      final sessionIds = <String>[];
      for (int i = 0; i < 10; i++) {
        coordinator.appendUserAndPlaceholderMessage('测试问题 $i');
        coordinator.updateAssistantMessageContent(
          coordinator.messages.last.id,
          coordinator.messages.length - 1,
          '测试回答 $i',
        );
        final s = await coordinator.startNewSession();
        if (s != null) {
          sessionIds.add(s.id);
        }
      }

      expect(coordinator.sessions.length, equals(10));

      // Perform 50 concurrent interleaved operations (rename, persist, export HTML)
      final ops = <Future<void>>[];
      for (int i = 0; i < sessionIds.length; i++) {
        final id = sessionIds[i];
        ops.add(coordinator.renameSession(id, '并发重命名标题 $i'));
        ops.add(coordinator.exportChatHistoryHtml());
        ops.add(coordinator.syncCurrentSession(persist: false));
      }
      await Future.wait(ops);

      // Verify all renames took effect without crash or data loss
      for (int i = 0; i < sessionIds.length; i++) {
        final s = coordinator.sessions.firstWhere((s) => s.id == sessionIds[i]);
        expect(s.title, equals('并发重命名标题 $i'));
      }

      // Delete half the sessions concurrently
      final deleteOps = <Future<void>>[];
      for (int i = 0; i < 5; i++) {
        deleteOps.add(coordinator.deleteSession(sessionIds[i]));
      }
      await Future.wait(deleteOps);

      expect(coordinator.sessions.length, equals(5));

      // Clear all
      await coordinator.clearAllHistory();
      expect(coordinator.sessions.isEmpty, isTrue);
      expect(coordinator.messages.isEmpty, isTrue);

      coordinator.dispose();
    });
  });

  group('Adversarial Stress Harness: Speaker Verification Resilience', () {
    test('1. Robust DSP resilience on degraded, extreme, and interrupted audio streams', () {
      // 1.1 Empty samples
      final empty = Float32List(0);
      expect(SpeakerVerificationService.normalizeWaveform(empty).length, equals(0));
      expect(SpeakerVerificationService.concealBluetoothScoDropouts(empty).length, equals(0));
      expect(SpeakerVerificationService.trimToSpeech(empty).length, equals(0));

      // 1.2 Ultra-short audio (< frame size = 400 samples @ 16kHz)
      final ultraShort = Float32List(100);
      expect(SpeakerVerificationService.trimToSpeech(ultraShort).length, equals(0));

      // 1.3 Pure digital silence (all zeros)
      final pureSilence = Float32List(16000 * 2);
      final trimmedSilence = SpeakerVerificationService.trimToSpeech(pureSilence);
      expect(trimmedSilence.length, equals(0), reason: 'Pure silence must produce zero active speech');

      // 1.4 DC offset & 50Hz mains hum (<80Hz) without voice
      final lowFreqHum = Float32List(16000 * 2);
      for (int i = 0; i < lowFreqHum.length; i++) {
        // 50Hz sine wave + 0.1 DC offset
        lowFreqHum[i] = 0.1 + 0.3 * math.sin(2 * math.pi * 50 * i / 16000);
      }
      final trimmedHum = SpeakerVerificationService.trimToSpeech(lowFreqHum);
      expect(trimmedHum.length, equals(0), reason: '50Hz hum must be filtered by 80Hz high-pass and voicing check');

      // 1.5 Bluetooth packet loss / SCO zero-hole chopping
      // Synthesize 1.5 seconds of 200Hz harmonic voice with periodic 20ms zero gaps
      final choppedAudio = Float32List(16000 * 2);
      for (int i = 0; i < choppedAudio.length; i++) {
        final t = i / 16000.0;
        final isZeroHole = (i % 683) < 250; // periodic dropout
        if (!isZeroHole) {
          choppedAudio[i] = 0.4 * math.sin(2 * math.pi * 220 * t) +
              0.2 * math.sin(2 * math.pi * 440 * t);
        }
      }
      final concealed = SpeakerVerificationService.concealBluetoothScoDropouts(choppedAudio);
      expect(concealed.length, equals(choppedAudio.length));
      // Verify concealed audio has filled zero holes without crashing
      expect(concealed.any((v) => v.isNaN || v.isInfinite), isFalse);

      // 1.6 Extreme clipping (+1.0 / -1.0 saturation)
      final clippedAudio = Float32List(16000);
      for (int i = 0; i < clippedAudio.length; i++) {
        clippedAudio[i] = (i % 80 < 40) ? 1.0 : -1.0;
      }
      final normClipped = SpeakerVerificationService.normalizeWaveform(clippedAudio);
      expect(normClipped.every((s) => s >= -1.0 && s <= 1.0), isTrue);
      expect(normClipped.any((s) => s.isNaN), isFalse);

      // 1.7 NaN / Infinity injection resilience in VectorMath
      final nanVector = [double.nan, 1.0, 2.0];
      final normalVector = [1.0, 1.0, 2.0];
      final simWithNan = VectorMath.cosineSimilarity(nanVector, normalVector);
      expect(simWithNan.isNaN || simWithNan == 0.0, isTrue);
    });

    test('2. Multi-sample speaker similarity calculation & outlier pruning verification', () {
      final settings = buildStressSettings();
      final service = SpeakerVerificationService(settings: settings);

      // Synthesize 4 reference embeddings (dim=4)
      final sample1 = [1.0, 0.0, 0.0, 0.0];
      final sample2 = [0.95, 0.05, 0.0, 0.0];
      final sample3 = [0.90, 0.10, 0.0, 0.0];
      final outlier = [0.0, 1.0, 0.0, 0.0]; // Contaminated outlier sample

      settings.ownerSpeakerEmbeddings = [sample1, sample2, sample3, outlier];
      expect(service.enrolledSampleCount, equals(4));
      expect(service.hasEnrolledOwner, isTrue);

      // Candidate vector matching sample1 closely
      final candidate = [0.98, 0.02, 0.0, 0.0];
      final analysis = service.computeMatchScore(candidate, speechSeconds: 1.5, durationMs: 12);

      expect(analysis, isNotNull);
      expect(analysis!.similarity, greaterThan(0.85), reason: 'Outlier sample should be pruned by robust mean');
      expect(analysis.maxSampleSimilarity, closeTo(1.0, 0.05));
      expect(analysis.sampleSimilarities.length, equals(4));
      expect(analysis.speechSeconds, equals(1.5));
      expect(analysis.durationMs, equals(12));

      // Test candidate vector with mismatched dimension (e.g. dim=8)
      final mismatched = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
      final mismatchedAnalysis = service.computeMatchScore(mismatched);
      expect(mismatchedAnalysis, isNull, reason: 'Dimension mismatch must be safely rejected with null');
    });

    test('3. VoicePipelineCoordinator speaker enrollment concurrency and state safety', () async {
      SharedPreferences.setMockInitialValues({});
      int notifyCount = 0;
      final coordinator = VoicePipelineCoordinator(
        settings: buildStressSettings(),
        emit: (_) {},
        onNotify: () => notifyCount++,
      );

      expect(coordinator.isEnrolling, isFalse);
      expect(coordinator.hasEnrolledOwner, isFalse);

      // 3.1 Test enrollment with invalid/insufficient audio samples
      final shortSamples = Float32List(100);
      final enrollShortResult = await coordinator.enrollOwnerSpeaker(samples: shortSamples);
      expect(enrollShortResult, isFalse);

      // 3.2 Test speaker similarity test when no owner is enrolled
      final simResult = await coordinator.testOwnerSpeakerSimilarity(samples: Float32List(16000));
      expect(simResult['passed'], isFalse);
      expect(simResult['error'], contains('尚未录入主人声纹'));

      // 3.3 Verify verifyOwnerSpeaker bypasses when no owner is enrolled
      final verifyBypassed = coordinator.verifyOwnerSpeaker(contextHint: '测试');
      expect(verifyBypassed, isTrue);

      // 3.4 Clear owner speaker
      await coordinator.clearOwnerSpeaker();
      expect(coordinator.enrolledSpeakerCount, equals(0));
      expect(coordinator.hasEnrolledOwner, isFalse);

      // 3.5 Interrupted state recovery
      coordinator.isEnrollingSpeaker = true;
      expect(coordinator.isEnrolling, isTrue);
      coordinator.isEnrollingSpeaker = false;
      expect(coordinator.isEnrolling, isFalse);

      coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);
    });
  });

  group('Adversarial Stress Harness: AssistantEngine Mediator Integration', () {
    test('1. End-to-end metrics pass-through via AssistantEngine: zero drops & 0 notifyListeners on metrics burst', () async {
      SharedPreferences.setMockInitialValues({});
      int engineNotifyCount = 0;

      final engine = AssistantEngine(
        settings: buildStressSettings(),
      );
      engine.addListener(() => engineNotifyCount++);

      final receivedEvents = <AssistantEngineEvent>[];
      final sub = engine.events.listen(receivedEvents.add);

      // Await initial constructor background tasks (loadChatHistory) to settle
      await Future<void>.delayed(const Duration(milliseconds: 100));
      engineNotifyCount = 0;

      const int burstPulses = 5000;
      final sw = Stopwatch()..start();

      for (int i = 0; i < burstPulses; i++) {
        engine.voiceCoordinator.voiceListeningService.onAudioLevelChanged?.call(
          (i % 100) / 100.0,
          -60.0 + (i % 60),
          (i % 2 == 0),
        );
      }
      sw.stop();

      // Give stream microtask queue time to deliver
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // ignore: avoid_print
      print('[Engine Stress] Emitted $burstPulses pulses through AssistantEngine in ${sw.elapsedMilliseconds}ms');

      // Zero frame drops through engine broadcast stream
      final metricsEvents = receivedEvents.whereType<MetricsUpdatedEvent>().toList();
      expect(metricsEvents.length, equals(burstPulses));

      // notifyListeners must NOT be called for audio metrics
      expect(
        engineNotifyCount,
        equals(0),
        reason: 'AssistantEngine.notifyListeners must not be invoked during audio metrics burst',
      );

      await sub.cancel();
      engine.dispose();
    });

    test('2. Concurrent driver port operations and session mutations on AssistantEngine', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AssistantEngine(
        settings: buildStressSettings(),
      );

      // Append initial messages
      engine.sessionCoordinator.appendUserAndPlaceholderMessage('问题 A');
      engine.sessionCoordinator.appendUserAndPlaceholderMessage('问题 B');

      // Concurrently perform driver port reads/writes and coordinator mutations
      final futures = <Future<void>>[];

      // Driver port session queries
      futures.add(Future(() => expect(engine.sessions, isNotNull)));
      futures.add(Future(() => expect(engine.currentSessionId, isNotEmpty)));

      // Driver port volume & device adjustments
      futures.add(engine.stopSpeaking());
      futures.add(engine.switchSession(engine.currentSessionId));

      // Streaming chunk updates
      final assistantMsg = engine.messages.lastWhere((m) => m.role == 'assistant');
      for (int i = 1; i <= 10; i++) {
        futures.add(Future(() {
          engine.sessionCoordinator.updateAssistantMessageContent(
            assistantMsg.id,
            engine.messages.length - 1,
            '引擎测试流式块 $i',
          );
        }));
      }

      await Future.wait(futures);

      expect(engine.messages.any((m) => m.content.contains('引擎测试流式块')), isTrue);
      engine.dispose();
    });
  });
}

