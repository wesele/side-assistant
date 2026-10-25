import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

String? _customDataDirPath;

void configureCustomDataDir(String path) {
  _customDataDirPath = path;
}

Directory resolveBaseDataDir() {
  if (_customDataDirPath != null && _customDataDirPath!.trim().isNotEmpty) {
    final dir = Directory(_customDataDirPath!.trim());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
  final envDir = Platform.environment['SIDE_ASSISTANT_DATA_DIR'];
  if (envDir != null && envDir.trim().isNotEmpty) {
    final dir = Directory(envDir.trim());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  final dir = Directory(p.join(home, '.local', 'share', 'side_assistant'));
  if (!dir.existsSync()) {
    try {
      dir.createSync(recursive: true);
    } catch (_) {
      return Directory.current;
    }
  }
  return dir;
}

File _prefsFile() {
  return File(p.join(resolveBaseDataDir().path, 'preferences.json'));
}

Map<String, dynamic> _readAllPrefsSync() {
  final file = _prefsFile();
  if (!file.existsSync()) return <String, dynamic>{};
  try {
    final raw = file.readAsStringSync();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return <String, dynamic>{};
}

Future<String?> readPreferenceString(String key) async {
  final map = _readAllPrefsSync();
  final val = map[key];
  return val is String ? val : null;
}

Future<void> writePreferenceString(String key, String value) async {
  final map = _readAllPrefsSync();
  map[key] = value;
  final file = _prefsFile();
  if (!file.parent.existsSync()) {
    file.parent.createSync(recursive: true);
  }
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(map),
    flush: true,
  );
}

Future<Directory> getAppDocumentsDirectory() async {
  final dir = Directory(p.join(resolveBaseDataDir().path, 'documents'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

Future<Directory> getAppSupportDirectory() async {
  final dir = Directory(p.join(resolveBaseDataDir().path, 'support'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

Future<Directory> getAppTemporaryDirectory() async {
  final dir = Directory(p.join(Directory.systemTemp.path, 'side_assistant'));
  if (!dir.existsSync()) {
    try {
      dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return Directory.systemTemp;
    }
  }
  return dir;
}

Future<Uint8List?> loadAssetBytes(String assetPath) async {
  final normalized = assetPath.replaceAll('/', Platform.pathSeparator);
  final candidates = <String>[
    assetPath,
    normalized,
    p.join(Directory.current.path, normalized),
    p.join(p.dirname(Platform.resolvedExecutable), normalized),
    p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets', normalized),
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      try {
        return await f.readAsBytes();
      } catch (_) {}
    }
  }
  return null;
}

void evictAsset(String assetPath) {}
