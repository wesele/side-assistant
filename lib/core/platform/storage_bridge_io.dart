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
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (e) {
    stderr.writeln('[StorageBridge] preferences.json 解析异常: $e，尝试读取备份文件...');
    final bakFile = File('${file.path}.bak');
    if (bakFile.existsSync()) {
      try {
        final bakRaw = bakFile.readAsStringSync();
        final decoded = jsonDecode(bakRaw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
  }
  return <String, dynamic>{};
}

Future<String?> readPreferenceString(String key) async {
  final map = _readAllPrefsSync();
  final val = map[key];
  return val is String ? val : null;
}

Future<void> writePreferenceString(String key, String value) async {
  final file = _prefsFile();
  final map = _readAllPrefsSync();

  // 安全防线：若已有 preferences.json 显著非空，但 map 为空，说明文件可能被锁或临时损坏，严禁盲目覆盖！
  if (file.existsSync() && file.lengthSync() > 10 && map.isEmpty) {
    stderr.writeln('[StorageBridge] 拒绝写入：现有 preferences.json 非空但未能解析出已有配置，放弃盲目覆盖以防冲掉数据！');
    return;
  }

  // 写入前自动将上一版成功配置备份为 preferences.json.bak
  if (file.existsSync() && file.lengthSync() > 0) {
    try {
      final bakFile = File('${file.path}.bak');
      file.copySync(bakFile.path);
    } catch (_) {}
  }

  map[key] = value;
  if (!file.parent.existsSync()) {
    file.parent.createSync(recursive: true);
  }

  // 原子写入：先写入临时文件，再 rename，防止并发写入或意外中断导致空文件
  final tmpFile = File('${file.path}.tmp_${DateTime.now().millisecondsSinceEpoch}');
  try {
    await tmpFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(map),
      flush: true,
    );
    if (tmpFile.existsSync()) {
      tmpFile.renameSync(file.path);
    }
  } catch (e) {
    stderr.writeln('[StorageBridge] 原子写入 preferences.json 异常: $e');
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } catch (_) {}
  }
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
