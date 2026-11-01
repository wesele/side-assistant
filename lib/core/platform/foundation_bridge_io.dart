import 'dart:io';
export 'dart:typed_data';

typedef VoidCallback = void Function();

const bool kIsWeb = false;

bool get isAndroidPlatform => Platform.isAndroid;

bool get isRunningInFlutterTest =>
    Platform.environment.containsKey('FLUTTER_TEST');

class _VisibleForTesting {
  const _VisibleForTesting();
}

const Object visibleForTesting = _VisibleForTesting();

void debugPrint(String? message, {int? wrapWidth}) {
  if (message != null) {
    // ignore: avoid_print
    print(message);
  }
}

/// Pure Dart implementation of Flutter's [Listenable] contract.
abstract class Listenable {
  const Listenable();

  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

class ChangeNotifier implements Listenable {
  final List<VoidCallback> _listeners = <VoidCallback>[];
  bool _disposed = false;

  bool get hasListeners => _listeners.isNotEmpty;

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    if (_disposed || _listeners.isEmpty) return;
    final snapshot = List<VoidCallback>.from(_listeners);
    for (final listener in snapshot) {
      try {
        listener();
      } catch (e, st) {
        debugPrint('[ChangeNotifier] listener error: $e\n$st');
      }
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}

abstract class ValueListenable<T> extends Listenable {
  const ValueListenable();

  T get value;
}

class ValueNotifier<T> extends ChangeNotifier implements ValueListenable<T> {
  T _value;

  ValueNotifier(this._value);

  @override
  T get value => _value;

  set value(T newValue) {
    if (_value == newValue) return;
    _value = newValue;
    notifyListeners();
  }
}
