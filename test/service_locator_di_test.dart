import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/di/app_container.dart';
import 'package:side_assistant/core/models/app_settings.dart';

class _FakeDisposableService {
  bool isDisposed = false;
  void dispose() {
    isDisposed = true;
  }
}

class _CounterService {
  static int _globalCount = 0;
  final int id;
  _CounterService() : id = ++_globalCount;
}

void main() {
  setUp(() {
    AppContainer.resetForTest();
  });

  tearDown(() {
    AppContainer.resetForTest();
  });

  group('AppContainer Service Locator & DI Tests', () {
    test('1. 立即单例注册与解析验证 (Singleton registration and resolution)', () {
      final container = AppContainer.instance;
      final settings = AppSettings(startWord: '小助手', endWord: '退下吧');

      container.registerSingleton<AppSettings>(settings);

      expect(container.has<AppSettings>(), isTrue);
      expect(container.isRegistered<AppSettings>(), isTrue);

      final resolved = container.get<AppSettings>();
      expect(identical(resolved, settings), isTrue);
      expect(resolved.startWord, '小助手');
      expect(resolved.endWord, '退下吧');

      final tryResolved = container.tryGet<AppSettings>();
      expect(identical(tryResolved, settings), isTrue);
    });

    test('2. 延迟单例懒加载与缓存验证 (Lazy singleton deferred factory & caching)', () {
      final container = AppContainer.instance;
      int factoryCallCount = 0;

      container.registerLazySingleton<_CounterService>(() {
        factoryCallCount++;
        return _CounterService();
      });

      // 注册后尚未解析，factory 不应被调用
      expect(factoryCallCount, equals(0));
      expect(container.has<_CounterService>(), isTrue);

      // 首次 get() 触发构建
      final instance1 = container.get<_CounterService>();
      expect(factoryCallCount, equals(1));

      // 二次 get() 复用缓存
      final instance2 = container.get<_CounterService>();
      expect(factoryCallCount, equals(1));
      expect(identical(instance1, instance2), isTrue);
      expect(instance1.id, equals(instance2.id));
    });

    test('3. 瞬态工厂每次解析生成全新实例 (Transient factory creates new instances)', () {
      final container = AppContainer.instance;
      int buildCount = 0;

      container.registerFactory<_CounterService>(() {
        buildCount++;
        return _CounterService();
      });

      expect(buildCount, equals(0));

      final first = container.get<_CounterService>();
      final second = container.get<_CounterService>();
      final third = container.get<_CounterService>();

      expect(buildCount, equals(3));
      expect(identical(first, second), isFalse);
      expect(identical(second, third), isFalse);
      expect(first.id, isNot(equals(second.id)));
      expect(second.id, isNot(equals(third.id)));
    });

    test('4. 命名服务隔离注册与解析 (Named service registrations)', () {
      final container = AppContainer.instance;
      final defaultSettings = AppSettings(playbackVolume: 50);
      final customSettings = AppSettings(playbackVolume: 90);

      container.registerSingleton<AppSettings>(defaultSettings);
      container.registerSingleton<AppSettings>(customSettings, name: 'custom');

      expect(container.has<AppSettings>(), isTrue);
      expect(container.has<AppSettings>('custom'), isTrue);
      expect(container.has<AppSettings>('non_existent'), isFalse);

      final resolvedDefault = container.get<AppSettings>();
      final resolvedCustom = container.get<AppSettings>('custom');

      expect(resolvedDefault.playbackVolume, equals(50));
      expect(resolvedCustom.playbackVolume, equals(90));
      expect(identical(resolvedDefault, resolvedCustom), isFalse);
    });

    test('5. 单元测试隔离覆盖 registerOverride (Test override behavior)', () {
      final container = AppContainer.instance;
      final originalSettings = AppSettings(playbackVolume: 30);
      final mockSettings = AppSettings(playbackVolume: 100);

      container.registerSingleton<AppSettings>(originalSettings);
      expect(container.get<AppSettings>().playbackVolume, equals(30));

      // 测试环境强制覆盖
      container.registerOverride<AppSettings>(mockSettings);
      expect(container.get<AppSettings>().playbackVolume, equals(100));
      expect(identical(container.get<AppSettings>(), mockSettings), isTrue);
    });

    test(
        '6. 未注册服务解析抛出类型化异常 (Unregistered service throws ServiceNotFoundException)',
        () {
      final container = AppContainer.instance;

      expect(container.has<_CounterService>(), isFalse);
      expect(container.tryGet<_CounterService>(), isNull);

      expect(
        () => container.get<_CounterService>(),
        throwsA(
          isA<ServiceNotFoundException>().having(
            (e) => e.toString(),
            'message',
            contains('_CounterService'),
          ),
        ),
      );
    });

    test('7. 容器生命周期销毁与 resetForTest 状态复位 (Lifecycle disposal and reset)',
        () async {
      final container = AppContainer.instance;
      final serviceA = _FakeDisposableService();
      final serviceB = _FakeDisposableService();

      container.registerSingleton<_FakeDisposableService>(
        serviceA,
        name: 'a',
        onDispose: (s) => s.dispose(),
      );
      container.registerSingleton<_FakeDisposableService>(
        serviceB,
        name: 'b',
        onDispose: (s) => s.dispose(),
      );

      expect(serviceA.isDisposed, isFalse);
      expect(serviceB.isDisposed, isFalse);

      // 单个注销
      container.unregister<_FakeDisposableService>('a');
      expect(serviceA.isDisposed, isTrue);
      expect(serviceB.isDisposed, isFalse);
      expect(container.has<_FakeDisposableService>('a'), isFalse);
      expect(container.has<_FakeDisposableService>('b'), isTrue);

      // 全局测试复位
      AppContainer.resetForTest();
      expect(serviceB.isDisposed, isTrue);

      // 验证重置后容器为空
      final freshContainer = AppContainer.instance;
      expect(freshContainer.has<_FakeDisposableService>('b'), isFalse);
    });
  });
}
