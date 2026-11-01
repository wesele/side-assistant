import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/di/app_container.dart';

class _StressDummyService {
  final int id;
  bool isDisposed = false;
  _StressDummyService(this.id);
  void dispose() {
    isDisposed = true;
  }
}

class _FaultyDisposableService {
  bool isDisposed = false;
  void dispose() {
    isDisposed = true;
    throw Exception('Simulated dispose failure');
  }
}

// Circular dependency mock classes
class _NodeA {
  final _NodeB? b;
  _NodeA([this.b]);
}

class _NodeB {
  final _NodeA? a;
  _NodeB([this.a]);
}

class _SelfReferential {
  final _SelfReferential? self;
  _SelfReferential([this.self]);
}

void main() {
  setUp(() {
    AppContainer.resetForTest();
  });

  tearDown(() {
    AppContainer.resetForTest();
  });

  group('1. Concurrent Resolution Stress Tests (1000+ parallel async tasks)', () {
    test('1.1 Parallel async resolution of Singleton (2000 concurrent requests)', () async {
      final container = AppContainer.instance;
      final expectedInstance = _StressDummyService(100);
      container.registerSingleton<_StressDummyService>(expectedInstance);

      const int concurrentCount = 2000;
      final futures = List<Future<_StressDummyService>>.generate(
        concurrentCount,
        (i) async {
          if (i % 3 == 0) await Future.delayed(Duration.zero);
          if (i % 5 == 0) await Future.microtask(() {});
          return container.get<_StressDummyService>();
        },
      );

      final results = await Future.wait(futures);

      expect(results.length, equals(concurrentCount));
      for (final instance in results) {
        expect(identical(instance, expectedInstance), isTrue);
      }
    });

    test('1.2 Parallel async resolution of Lazy Singleton from cold start (2000 concurrent requests)', () async {
      final container = AppContainer.instance;
      int factoryInvocationCount = 0;

      container.registerLazySingleton<_StressDummyService>(() {
        factoryInvocationCount++;
        return _StressDummyService(200);
      });

      expect(factoryInvocationCount, equals(0));

      const int concurrentCount = 2000;
      final futures = List<Future<_StressDummyService>>.generate(
        concurrentCount,
        (i) async {
          if (i % 2 == 0) await Future.delayed(Duration.zero);
          if (i % 3 == 0) await Future.microtask(() {});
          return container.get<_StressDummyService>();
        },
      );

      final results = await Future.wait(futures);

      expect(factoryInvocationCount, equals(1),
          reason: 'Lazy singleton factory must be invoked exactly once even under 2000 concurrent cold-start requests');
      expect(results.length, equals(concurrentCount));
      final first = results.first;
      for (final instance in results) {
        expect(identical(instance, first), isTrue);
      }
    });

    test('1.3 Parallel async resolution of Transient Factory (2000 concurrent requests)', () async {
      final container = AppContainer.instance;
      int factoryInvocationCount = 0;

      container.registerFactory<_StressDummyService>(() {
        factoryInvocationCount++;
        return _StressDummyService(factoryInvocationCount);
      });

      const int concurrentCount = 2000;
      final futures = List<Future<_StressDummyService>>.generate(
        concurrentCount,
        (i) async {
          if (i % 4 == 0) await Future.microtask(() {});
          return container.get<_StressDummyService>();
        },
      );

      final results = await Future.wait(futures);

      expect(factoryInvocationCount, equals(concurrentCount),
          reason: 'Transient factory must be invoked once per resolution request');
      expect(results.length, equals(concurrentCount));

      // Verify all instances are unique objects
      final identitySet = results.map((e) => identityHashCode(e)).toSet();
      expect(identitySet.length, equals(concurrentCount),
          reason: 'All 2000 transient factory instances must be distinct memory references');
    });

    test('1.4 High concurrency mixed resolution stress (3000 requests across mixed service types and names)', () async {
      final container = AppContainer.instance;
      final singleInst = _StressDummyService(1);
      int lazyCount = 0;
      int factoryCount = 0;

      container.registerSingleton<_StressDummyService>(singleInst, name: 'singleton');
      container.registerLazySingleton<_StressDummyService>(() {
        lazyCount++;
        return _StressDummyService(2);
      }, name: 'lazy');
      container.registerFactory<_StressDummyService>(() {
        factoryCount++;
        return _StressDummyService(1000 + factoryCount);
      }, name: 'factory');

      const int totalRequests = 3000;
      final futures = List<Future<void>>.generate(totalRequests, (i) async {
        final mod = i % 3;
        if (mod == 0) {
          final res = container.get<_StressDummyService>('singleton');
          expect(identical(res, singleInst), isTrue);
        } else if (mod == 1) {
          final res = container.get<_StressDummyService>('lazy');
          expect(res.id, equals(2));
        } else {
          final res = container.get<_StressDummyService>('factory');
          expect(res.id, greaterThan(1000));
        }
      });

      await Future.wait(futures);

      expect(lazyCount, equals(1));
      expect(factoryCount, equals(totalRequests ~/ 3));
    });
  });

  group('2. Race Condition & Lifecycle Behavior of Lazy Singletons', () {
    test('2.1 Lazy singleton factory throwing error propagates cleanly and allows subsequent retry', () {
      final container = AppContainer.instance;
      int callAttempts = 0;
      bool shouldFail = true;

      container.registerLazySingleton<_StressDummyService>(() {
        callAttempts++;
        if (shouldFail) {
          throw FormatException('Initialization failed on attempt $callAttempts');
        }
        return _StressDummyService(42);
      });

      // First resolution fails
      expect(
        () => container.get<_StressDummyService>(),
        throwsA(isA<FormatException>()),
      );
      expect(callAttempts, equals(1));

      // Fix condition and retry: factory should be invoked again because instance was not cached
      shouldFail = false;
      final recovered = container.get<_StressDummyService>();
      expect(recovered.id, equals(42));
      expect(callAttempts, equals(2));

      // Subsequent calls reuse the now-cached instance
      final cached = container.get<_StressDummyService>();
      expect(identical(cached, recovered), isTrue);
      expect(callAttempts, equals(2));
    });

    test('2.2 Nested dependency resolution between lazy singletons', () {
      final container = AppContainer.instance;
      int countB = 0;
      int countA = 0;

      container.registerLazySingleton<_NodeB>(() {
        countB++;
        return _NodeB();
      });

      container.registerLazySingleton<_NodeA>(() {
        countA++;
        return _NodeA(container.get<_NodeB>());
      });

      final a = container.get<_NodeA>();
      expect(countA, equals(1));
      expect(countB, equals(1));
      expect(a.b, isNotNull);

      final a2 = container.get<_NodeA>();
      expect(countA, equals(1));
      expect(countB, equals(1));
      expect(identical(a, a2), isTrue);
    });
  });

  group('3. Test Override Safety & Cross-Test Isolation', () {
    test('3.1 registerOverride replaces existing singleton', () {
      final container = AppContainer.instance;
      final real = _StressDummyService(1);
      final mock = _StressDummyService(999);

      container.registerSingleton<_StressDummyService>(real);
      expect(container.get<_StressDummyService>().id, equals(1));

      container.registerOverride<_StressDummyService>(mock);
      expect(container.get<_StressDummyService>().id, equals(999));
      expect(identical(container.get<_StressDummyService>(), mock), isTrue);
    });

    test('3.2 registerOverride replaces existing lazy singleton', () {
      final container = AppContainer.instance;
      bool lazyCalled = false;
      container.registerLazySingleton<_StressDummyService>(() {
        lazyCalled = true;
        return _StressDummyService(1);
      });

      final mock = _StressDummyService(888);
      container.registerOverride<_StressDummyService>(mock);

      expect(container.get<_StressDummyService>().id, equals(888));
      expect(lazyCalled, isFalse, reason: 'Overridden lazy factory should never be called');
    });

    test('3.3 resetForTest completely purges all state and prevents leakage across tests', () {
      final container = AppContainer.instance;
      container.registerSingleton<_StressDummyService>(_StressDummyService(123));
      container.registerOverride<_StressDummyService>(_StressDummyService(456));

      expect(container.has<_StressDummyService>(), isTrue);

      AppContainer.resetForTest();

      final newContainer = AppContainer.instance;
      expect(newContainer.has<_StressDummyService>(), isFalse);
      expect(newContainer.tryGet<_StressDummyService>(), isNull);
    });

    test('3.4 Disposal resilience: fault in one onDispose does not abort other disposals', () {
      final container = AppContainer.instance;
      final faulty = _FaultyDisposableService();
      final normal = _StressDummyService(1);

      container.registerSingleton<_FaultyDisposableService>(
        faulty,
        onDispose: (s) => s.dispose(),
      );
      container.registerSingleton<_StressDummyService>(
        normal,
        onDispose: (s) => s.dispose(),
      );

      // resetForTest should swallow faulty's exception and continue disposing normal
      expect(() => AppContainer.resetForTest(), returnsNormally);

      expect(faulty.isDisposed, isTrue);
      expect(normal.isDisposed, isTrue);
    });

    test('3.5 Override disposal behavior check (Observation test)', () {
      final container = AppContainer.instance;
      final original = _StressDummyService(1);
      final override = _StressDummyService(2);

      container.registerSingleton<_StressDummyService>(
        original,
        onDispose: (s) => s.dispose(),
      );

      container.registerOverride<_StressDummyService>(
        override,
        // note: registerOverride does not expose onDispose parameter
      );

      // Verify whether the original instance was disposed at the moment of override
      // In current implementation, registerOverride overwrites the map entry without calling dispose()
      expect(original.isDisposed, isFalse,
          reason: 'Current implementation does not dispose the overridden instance at override time');
    });
  });

  group('4. Negative Testing: Unregistered, Circular Resolution, Null Handling', () {
    test('4.1 Unregistered services throw ServiceNotFoundException or return null on tryGet', () {
      final container = AppContainer.instance;

      expect(container.has<_StressDummyService>(), isFalse);
      expect(container.tryGet<_StressDummyService>(), isNull);
      expect(
        () => container.get<_StressDummyService>(),
        throwsA(isA<ServiceNotFoundException>().having(
          (e) => e.toString(),
          'message',
          contains('_StressDummyService'),
        )),
      );

      // Named service
      expect(container.has<_StressDummyService>('unknown_name'), isFalse);
      expect(container.tryGet<_StressDummyService>('unknown_name'), isNull);
      expect(
        () => container.get<_StressDummyService>('unknown_name'),
        throwsA(isA<ServiceNotFoundException>().having(
          (e) => e.toString(),
          'message',
          contains('unknown_name'),
        )),
      );
    });

    test('4.2 Duplicate registration without allowOverride throws StateError', () {
      final container = AppContainer.instance;
      container.registerSingleton<_StressDummyService>(_StressDummyService(1));

      expect(
        () => container.registerSingleton<_StressDummyService>(_StressDummyService(2)),
        throwsStateError,
      );
      expect(
        () => container.registerLazySingleton<_StressDummyService>(() => _StressDummyService(3)),
        throwsStateError,
      );
      expect(
        () => container.registerFactory<_StressDummyService>(() => _StressDummyService(4)),
        throwsStateError,
      );
    });

    test('4.3 Circular dependency behavior: Direct self-referencing lazy singleton', () {
      final container = AppContainer.instance;

      container.registerLazySingleton<_SelfReferential>(() {
        return _SelfReferential(container.get<_SelfReferential>());
      });

      // Does it throw StackOverflowError or CircularDependencyException?
      expect(
        () => container.get<_SelfReferential>(),
        throwsA(anyOf(
          isA<StackOverflowError>(),
          isA<StateError>(),
          isA<Exception>(),
        )),
      );
    });

    test('4.4 Circular dependency behavior: Two-node mutually recursive lazy singletons', () {
      final container = AppContainer.instance;

      container.registerLazySingleton<_NodeA>(() {
        return _NodeA(container.get<_NodeB>());
      });

      container.registerLazySingleton<_NodeB>(() {
        return _NodeB(container.get<_NodeA>());
      });

      expect(
        () => container.get<_NodeA>(),
        throwsA(anyOf(
          isA<StackOverflowError>(),
          isA<StateError>(),
          isA<Exception>(),
        )),
      );
    });

    test('4.5 Null handling: registering null for nullable type or null-returning factory', () {
      final container = AppContainer.instance;

      // Notice: registerSingleton<String?> with null
      container.registerSingleton<String?>(null, allowOverride: true);

      // In current implementation:
      // case _RegistrationType.singleton: return instance!;
      // When instance is null, `instance!` throws Null check operator used on null value.
      expect(
        () => container.get<String?>(),
        throwsA(isA<TypeError>()),
        reason: 'Current implementation uses instance! which throws TypeError if instance is null',
      );

      // Lazy singleton returning null
      container.registerLazySingleton<int?>(() => null, allowOverride: true);
      expect(
        () => container.get<int?>(),
        throwsA(isA<TypeError>()),
        reason: 'Lazy singleton also uses instance! which throws on null',
      );
    });
  });
}
