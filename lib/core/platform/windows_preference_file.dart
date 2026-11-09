import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Writes the existing shared_preferences_windows file without truncating it.
/// Keys (including the `flutter.` prefix) and unrelated data are preserved.
class WindowsPreferenceFile {
  WindowsPreferenceFile({required this.resolveFile});

  final Future<File> Function() resolveFile;
  Future<void> _pendingWrite = Future<void>.value();
  int _sequence = 0;

  Future<void> writeString(String key, String value) {
    final write = _pendingWrite.then((_) => _writeString(key, value));
    // A failed save must reach its caller without poisoning subsequent saves.
    _pendingWrite =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  Future<void> _writeString(String key, String value) async {
    final file = await resolveFile();
    final preferences = <String, dynamic>{};
    if (await file.exists()) {
      // Refuse to turn an unreadable or corrupt existing file into defaults.
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
            'Windows preferences must contain a JSON object');
      }
      preferences.addAll(decoded);
      await file.copy('${file.path}.bak');
    } else {
      await file.parent.create(recursive: true);
    }

    preferences[key] = value;
    final temporary = File('${file.path}.tmp.$pid.${_sequence++}');
    try {
      await temporary.writeAsString(jsonEncode(preferences), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
