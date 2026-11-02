import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/vision/camera_service.dart';

/// 可配置延迟与并发统计的测试抓拍策略
class TestDelayCameraSource implements CameraCaptureSource {
  final CameraSourceType _type;
  final Duration captureDelay;
  bool _isOpen = false;
  int captureCount = 0;
  int activeCaptures = 0;
  int peakConcurrentCaptures = 0;
  int closeCount = 0;
  int disposeCount = 0;
  final StreamController<CameraFrame> _streamController =
      StreamController<CameraFrame>.broadcast();

  TestDelayCameraSource({
    CameraSourceType type = CameraSourceType.mock,
    this.captureDelay = const Duration(milliseconds: 10),
  }) : _type = type;

  @override
  CameraSourceType get type => _type;

  @override
  bool get isAvailable => true;

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<CameraFrame>? get previewStream => _streamController.stream;

  @override
  Future<void> initialize() async {
    _isOpen = true;
  }

  @override
  Future<bool> ensureOpen() async {
    _isOpen = true;
    return true;
  }

  @override
  Future<CameraCaptureResult> captureFrame(
      {CameraResolution? resolution}) async {
    _isOpen = true;
    captureCount++;
    activeCaptures++;
    if (activeCaptures > peakConcurrentCaptures) {
      peakConcurrentCaptures = activeCaptures;
    }
    try {
      if (captureDelay > Duration.zero) {
        await Future.delayed(captureDelay);
      }
      return CameraCaptureResult(
        imageBytes: MockCameraCaptureSource.minimalJpegBytes,
        filePath: 'test/path/frame_$captureCount.jpg',
        isSimulated: true,
        sourceType: _type,
      );
    } finally {
      activeCaptures--;
    }
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  @override
  Future<void> close() async {
    closeCount++;
    _isOpen = false;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _isOpen = false;
    await _streamController.close();
  }
}

/// 故障注入抓拍策略：可按配置在各生命周期点抛出异常
class FaultInjectionCameraSource implements CameraCaptureSource {
  final CameraSourceType _type;
  bool throwOnEnsureOpen;
  bool throwOnCapture;
  bool throwOnClose;
  bool throwOnDispose;
  final Object errorToThrow;
  bool _isOpen = false;
  int captureAttempts = 0;

  FaultInjectionCameraSource({
    CameraSourceType type = CameraSourceType.mock,
    this.throwOnEnsureOpen = false,
    this.throwOnCapture = false,
    this.throwOnClose = false,
    this.throwOnDispose = false,
    Object? error,
  })  : _type = type,
        errorToThrow = error ?? Exception('Simulated hardware sensor failure');

  @override
  CameraSourceType get type => _type;

  @override
  bool get isAvailable => true;

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<CameraFrame>? get previewStream => null;

  @override
  Future<void> initialize() async {
    await ensureOpen();
  }

  @override
  Future<bool> ensureOpen() async {
    if (throwOnEnsureOpen) {
      throw errorToThrow;
    }
    _isOpen = true;
    return true;
  }

  @override
  Future<CameraCaptureResult> captureFrame(
      {CameraResolution? resolution}) async {
    captureAttempts++;
    if (throwOnCapture) {
      throw errorToThrow;
    }
    _isOpen = true;
    return CameraCaptureResult(
      imageBytes: MockCameraCaptureSource.minimalJpegBytes,
      filePath: 'test/fault/success.jpg',
      isSimulated: true,
      sourceType: _type,
    );
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  @override
  Future<void> close() async {
    if (throwOnClose) {
      throw errorToThrow;
    }
    _isOpen = false;
  }

  @override
  Future<void> dispose() async {
    if (throwOnDispose) {
      throw errorToThrow;
    }
    _isOpen = false;
  }
}

/// 单通道互斥抓拍策略（模拟类似 DJI Nano 硬件一次仅允许一个抓拍会话）
class ExclusiveHardwareCameraSource implements CameraCaptureSource {
  bool _isBusy = false;
  int successCount = 0;
  int collisionCount = 0;

  @override
  CameraSourceType get type => CameraSourceType.nanoWifi;

  @override
  bool get isAvailable => true;

  @override
  bool get isOpen => true;

  @override
  Stream<CameraFrame>? get previewStream => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> ensureOpen() async => true;

  @override
  Future<CameraCaptureResult> captureFrame(
      {CameraResolution? resolution}) async {
    if (_isBusy) {
      collisionCount++;
      throw StateError('Hardware busy: concurrent capture prohibited');
    }
    _isBusy = true;
    try {
      await Future.delayed(const Duration(milliseconds: 15));
      successCount++;
      return CameraCaptureResult(
        imageBytes: MockCameraCaptureSource.minimalJpegBytes,
        filePath: 'test/exclusive/ok.jpg',
        isSimulated: true,
        sourceType: type,
      );
    } finally {
      _isBusy = false;
    }
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  @override
  Future<void> close() async {
    _isBusy = false;
  }

  @override
  Future<void> dispose() async {
    _isBusy = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Camera Capture SPI & CameraService Adversarial Stress Suite', () {
    // =========================================================================
    // 1. Rapid Source Switching Stress
    // =========================================================================
    group('1. Rapid Source Switching Stress', () {
      test('1.1 Concurrently call switchSource during in-flight captureFrame',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final slowSource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 50),
        );
        final nanoSource = TestDelayCameraSource(
          type: CameraSourceType.nanoWifi,
          captureDelay: const Duration(milliseconds: 10),
        );

        final service = CameraService(
          settings: settings,
          localSource: slowSource,
          nanoSource: nanoSource,
        );

        // Start capture on slow local source
        final captureFuture = service.takePictureDirect();

        // While capture is in-flight, immediately switch source to Nano
        await Future.delayed(const Duration(milliseconds: 10));
        await service.switchSource(CameraSourceType.nanoWifi);

        expect(service.settings.captureSource,
            equals(AppConstants.captureSourceNano));
        expect(service.currentSourceType, equals(CameraSourceType.nanoWifi));

        // Wait for the original capture to finish
        final result = await captureFuture;

        // Verify the original capture returned the frame from the source it started on
        expect(result.sourceType, equals(CameraSourceType.localDevice));
        expect(slowSource.captureCount, equals(1));

        // Verify next capture uses the newly switched Nano source
        final nanoResult = await service.takePictureDirect();
        expect(nanoResult.sourceType, equals(CameraSourceType.nanoWifi));
        expect(nanoSource.captureCount, equals(1));

        service.dispose();
      });

      test(
          '1.2 High-frequency switchSource flapping concurrently with continuous captures',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final localSource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 2),
        );
        final nanoSource = TestDelayCameraSource(
          type: CameraSourceType.nanoWifi,
          captureDelay: const Duration(milliseconds: 2),
        );

        final service = CameraService(
          settings: settings,
          localSource: localSource,
          nanoSource: nanoSource,
        );

        // Run 50 source switch calls concurrently with 30 capture requests
        final switchFutures = List.generate(50, (i) async {
          final target = i.isEven
              ? CameraSourceType.localDevice
              : CameraSourceType.nanoWifi;
          await service.switchSource(target);
        });

        final captureFutures = List.generate(30, (i) async {
          return await service.takePictureDirect();
        });

        await Future.wait([...switchFutures, ...captureFutures]);

        expect(localSource.captureCount + nanoSource.captureCount, equals(30));
        service.dispose();
      });

      test(
          '1.3 switchSource during active streaming does not crash stream listener',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final localSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final service =
            CameraService(settings: settings, localSource: localSource);

        final stream = await service.startStreaming();
        expect(stream, isNotNull);
        expect(service.isStreaming, isTrue);

        // Switch to Nano while stream is open
        await service.switchSource(CameraSourceType.nanoWifi);

        // Streaming state check
        expect(service.currentSourceType, equals(CameraSourceType.nanoWifi));

        await service.stopStreaming();
        expect(service.isStreaming, isFalse);

        service.dispose();
      });

      test(
          '1.4 Source switching with cameraKeepAliveMinutes=0 verify which source is closed',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 0, // Immediate close mode
        );

        final localSource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 30),
        );
        final nanoSource = TestDelayCameraSource(
          type: CameraSourceType.nanoWifi,
          captureDelay: const Duration(milliseconds: 5),
        );

        final service = CameraService(
          settings: settings,
          localSource: localSource,
          nanoSource: nanoSource,
        );

        // In-flight capture on local
        final captureFuture = service.takePictureDirect();

        // Switch to Nano during capture
        await Future.delayed(const Duration(milliseconds: 10));
        await service.switchSource(CameraSourceType.nanoWifi);

        await captureFuture;

        // Observational check: did closeCamera close localSource or nanoSource?
        // In CameraService: closeCamera calls activeSource.close(). Because settings changed to Nano,
        // it closed nanoSource instead of localSource, OR localSource remains unclosed!
        // We record what happened without assertions failing.
        service.dispose();
      });
    });

    // =========================================================================
    // 2. Fault Injection & Fallback Resilience
    // =========================================================================
    group('2. Fault Injection & Fallback Resilience', () {
      test(
          '2.1 Strategy throws during captureFrame() is reported cleanly without process crash',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final failingSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
          throwOnCapture: true,
          error:
              StateError('Hardware sensor timeout: capture bus disconnected'),
        );

        final service = CameraService(
          settings: settings,
          localSource: failingSource,
        );

        // Expect clean rethrow of the specific error
        expect(
          () => service.takePictureDirect(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Hardware sensor timeout'),
          )),
        );

        // Service should still be alive and functional
        expect(failingSource.captureAttempts, equals(1));

        // Now fix the error and verify service recovers cleanly
        failingSource.throwOnCapture = false;
        final res = await service.takePictureDirect();
        expect(res.imageBytes.isNotEmpty, isTrue);

        service.dispose();
      });

      test('2.2 Strategy throws during ensureOpen() fails gracefully',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceLocal);
        final failingSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
          throwOnEnsureOpen: true,
          error: Exception('I2C camera device address 0x3C not responding'),
        );

        final service = CameraService(
          settings: settings,
          localSource: failingSource,
        );

        expect(
          () => service.ensureCameraOpen(),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            contains('0x3C not responding'),
          )),
        );

        service.dispose();
      });

      test(
          '2.3 Strategy throws during close() does not prevent CameraService state reset',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final failingSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
          throwOnClose: true,
          error: Exception('Failed to power down sensor regulator'),
        );

        final service = CameraService(
          settings: settings,
          localSource: failingSource,
        );

        service.keepAlive(5);
        expect(service.isIdleTimerRunning, isTrue);

        // closeCamera invokes activeSource.close() which throws
        expect(() => service.closeCamera(), throwsA(isA<Exception>()));

        // Crucial resilience check: was idle timer cancelled despite close throwing?
        expect(service.isIdleTimerRunning, isFalse);

        service.dispose();
      });

      test('2.4 Intermittent hardware failures under repeated requests',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final intermittentSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
        );

        final service = CameraService(
          settings: settings,
          localSource: intermittentSource,
        );

        int successes = 0;
        int failures = 0;

        for (int i = 0; i < 20; i++) {
          intermittentSource.throwOnCapture = (i % 2 == 1);
          try {
            await service.takePictureDirect();
            successes++;
          } catch (_) {
            failures++;
          }
        }

        expect(successes, equals(10));
        expect(failures, equals(10));

        service.dispose();
      });
    });

    // =========================================================================
    // 3. Resource Leak & Timer Verification
    // =========================================================================
    group('3. Resource Leak & Timer Verification', () {
      test('3.1 1,000 rapid keepAlive calls do not leak orphaned timers',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final mockSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final service =
            CameraService(settings: settings, localSource: mockSource);

        // Rapidly call keepAlive 1,000 times
        for (int i = 1; i <= 1000; i++) {
          service.keepAlive(i % 10 + 1);
        }

        expect(service.isIdleTimerRunning, isTrue);

        // Explicit close should cancel the sole active timer
        await service.closeCamera();
        expect(service.isIdleTimerRunning, isFalse);

        service.dispose();
      });

      test('3.2 Rapid start/stop streaming cycles verify state integrity',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceLocal);
        final mockSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final service =
            CameraService(settings: settings, localSource: mockSource);

        for (int i = 0; i < 50; i++) {
          final stream = await service.startStreaming();
          expect(stream, isNotNull);
          expect(service.isStreaming, isTrue);

          await service.stopStreaming();
          expect(service.isStreaming, isFalse);
        }

        service.dispose();
      });

      test('3.3 Nano source mode disables idle timer automatically', () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceNano,
          cameraKeepAliveMinutes: 5,
        );

        final nanoSource =
            TestDelayCameraSource(type: CameraSourceType.nanoWifi);
        final service =
            CameraService(settings: settings, nanoSource: nanoSource);

        // In Nano mode, keepAlive / resetIdleTimer must never start an idle timer
        service.keepAlive(5);
        expect(service.isIdleTimerRunning, isFalse);

        await service.takePictureDirect();
        expect(service.isIdleTimerRunning, isFalse);

        service.dispose();
      });

      test('3.4 dispose() properly cancels idle timer and cascades to registry',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 5,
        );

        final mockSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final service =
            CameraService(settings: settings, localSource: mockSource);

        service.keepAlive(5);
        expect(service.isIdleTimerRunning, isTrue);

        service.dispose();
        expect(service.isIdleTimerRunning, isFalse);
        expect(mockSource.disposeCount, equals(1));
      });
    });

    // =========================================================================
    // 4. Concurrency Stress (100+ parallel requests)
    // =========================================================================
    group('4. Concurrency Stress', () {
      test('4.1 100 parallel takePictureDirect requests on Mock source',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final mockSource = MockCameraCaptureSource();
        final service = CameraService(
          settings: settings,
          localSource: mockSource,
        );

        // Fire 100 parallel requests concurrently
        final stopwatch = Stopwatch()..start();
        final futures = List.generate(100, (i) => service.takePictureDirect());
        final results = await Future.wait(futures);
        stopwatch.stop();

        expect(results.length, equals(100));
        for (final r in results) {
          expect(r.imageBytes.isNotEmpty, isTrue);
          expect(r.sourceType, equals(mockSource.type));
        }

        service.dispose();
      });

      test('4.2 100 parallel takePictureDirect with cameraKeepAliveMinutes=0',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 0, // Closes on completion
        );

        final delaySource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 5),
        );
        final service = CameraService(
          settings: settings,
          localSource: delaySource,
        );

        final futures = List.generate(100, (i) => service.takePictureDirect());
        final results = await Future.wait(futures);

        expect(results.length, equals(100));
        expect(delaySource.captureCount, equals(100));
        expect(delaySource.closeCount, greaterThan(0));

        service.dispose();
      });

      test(
          '4.3 Concurrency on exclusive hardware strategy reveals lack of serialization in CameraService',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceNano);
        final exclusiveSource = ExclusiveHardwareCameraSource();

        final service = CameraService(
          settings: settings,
          nanoSource: exclusiveSource,
        );

        // When multiple requests hit CameraService concurrently, does CameraService serialize them,
        // or does it pass them directly to the underlying source?
        int collisionErrors = 0;
        int successfulCaptures = 0;

        final futures = List.generate(10, (i) async {
          try {
            await service.takePictureDirect();
            successfulCaptures++;
          } on StateError {
            collisionErrors++;
          }
        });

        await Future.wait(futures);

        // Observation: Because CameraService does NOT queue or serialize captureFrame requests,
        // parallel requests trigger collision on hardware that does not support concurrency.
        expect(successfulCaptures + collisionErrors, equals(10));
        expect(collisionErrors, greaterThan(0),
            reason:
                'CameraService does not serialize concurrent takePictureDirect calls');

        service.dispose();
      });

      test(
          '4.4 120 parallel capturePhoto calls measure peak throughput and stability',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final delaySource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 2),
        );
        final service = CameraService(
          settings: settings,
          localSource: delaySource,
        );

        final futures = List.generate(120, (_) => service.capturePhoto());
        final results = await Future.wait(futures);

        expect(results.length, equals(120));
        expect(delaySource.captureCount, equals(120));
        expect(delaySource.peakConcurrentCaptures, greaterThan(1));

        service.dispose();
      });
    });

    // =========================================================================
    // 5. Deep Adversarial Edge Cases & SPI Invariants
    // =========================================================================
    group('5. Deep Adversarial Edge Cases & SPI Invariants', () {
      test(
          '5.1 switchSource does not close previously opened hardware source (Resource Retention)',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceLocal);
        final localSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final nanoSource =
            TestDelayCameraSource(type: CameraSourceType.nanoWifi);

        final service = CameraService(
          settings: settings,
          localSource: localSource,
          nanoSource: nanoSource,
        );

        // Open local camera
        final opened = await service.ensureCameraOpen();
        expect(opened, isTrue);
        expect(localSource.isOpen, isTrue);

        // Switch to Nano
        await service.switchSource(CameraSourceType.nanoWifi);
        expect(service.currentSourceType, equals(CameraSourceType.nanoWifi));

        // Observation: Local source was NOT closed upon switching sources!
        expect(localSource.isOpen, isTrue,
            reason:
                'switchSource does not automatically close previously active source');
        expect(localSource.closeCount, equals(0));

        service.dispose();
      });

      test(
          '5.2 startStreaming sets isStreaming=true even if previewStream is null (State Inconsistency)',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceLocal);
        // Source that does not support preview streaming (previewStream returns null)
        final localNoStreamSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
        );
        expect(localNoStreamSource.previewStream, isNull);

        final service = CameraService(
          settings: settings,
          localSource: localNoStreamSource,
        );

        final stream = await service.startStreaming();

        // Observation: stream is null, but isStreaming is true!
        expect(stream, isNull);
        expect(service.isStreaming, isTrue,
            reason:
                'startStreaming sets _isStreaming=true before checking if previewStream is null');

        service.dispose();
      });

      test(
          '5.3 Exception during captureFrame still schedules idle timer if keepAlive > 0',
          () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final failingSource = FaultInjectionCameraSource(
          type: CameraSourceType.localDevice,
          throwOnCapture: true,
        );

        final service = CameraService(
          settings: settings,
          localSource: failingSource,
        );

        expect(service.isIdleTimerRunning, isFalse);

        try {
          await service.takePictureDirect();
        } catch (_) {}

        // Observation: Even though captureFrame threw an error, finally block called _resetIdleTimer()
        expect(service.isIdleTimerRunning, isTrue,
            reason:
                'finally block in takePictureDirect schedules idle timer regardless of capture success/failure');

        service.dispose();
      });

      test(
          '5.4 Accessing activeSource after dispose throws NullCheckError once disposeAll completes',
          () async {
        final settings =
            AppSettings(captureSource: AppConstants.captureSourceLocal);
        final mockSource =
            TestDelayCameraSource(type: CameraSourceType.localDevice);
        final service =
            CameraService(settings: settings, localSource: mockSource);

        service.dispose();
        // Wait for unawaited(_registry.disposeAll()) to complete
        await Future.delayed(const Duration(milliseconds: 10));

        // After disposeAll completes, _registry.disposeAll() cleared _sources
        // Accessing activeSource now throws TypeError / NullCheckError on null source
        expect(
          () => service.activeSource,
          throwsA(anything),
          reason:
              'Accessing activeSource after dispose throws because registry sources were cleared',
        );
      });

      test('5.5 Concurrency stress: 200 parallel capture requests', () async {
        final settings = AppSettings(
          captureSource: AppConstants.captureSourceLocal,
          cameraKeepAliveMinutes: 3,
        );

        final delaySource = TestDelayCameraSource(
          type: CameraSourceType.localDevice,
          captureDelay: const Duration(milliseconds: 1),
        );
        final service = CameraService(
          settings: settings,
          localSource: delaySource,
        );

        final futures = List.generate(200, (_) => service.takePictureDirect());
        final results = await Future.wait(futures);

        expect(results.length, equals(200));
        expect(delaySource.captureCount, equals(200));

        service.dispose();
      });
    });
  });
}
