import 'dart:async';
import 'dart:io';

/// 联网测试的公共壳子。
///
/// `dart:io` 在连接/句柄被回收时，偶尔会把 `SocketException: Reading from a
/// closed socket` **直接抛到 zone**，而不是交给我们 `await` 的那个 Future。
/// 在 `flutter_test` 里这会直接判当前测试失败（甚至报成“该测试已完成之后才失败”），
/// 但它跟被测逻辑无关。这里统一用 `runZonedGuarded` 兜住这条已知噪音，
/// 其它异常照常失败。
Future<T> runLiveNetworkTest<T>(Future<T> Function() body) {
  final completer = Completer<T>();
  runZonedGuarded(
    () async {
      try {
        final result = await body();
        if (!completer.isCompleted) completer.complete(result);
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    },
    (error, stack) {
      if (isKnownSocketNoise(error)) {
        // ignore: avoid_print
        print('⚠️  忽略测试环境噪音: $error');
        return;
      }
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  return completer.future;
}

bool isKnownSocketNoise(Object error) {
  final text = error.toString();
  return error is SocketException && text.contains('closed socket');
}
