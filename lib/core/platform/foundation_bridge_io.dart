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

class ChangeNotifier {
  final List<VoidCallback> _listeners = <VoidCallback>[];
  bool _disposed = false;

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(VoidCallback listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

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
