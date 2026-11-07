import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'storage_bridge_io.dart' as io_fallback;

bool _useCustomDataDir = false;

void configureCustomDataDir(String path) {
  _useCustomDataDir = path.trim().isNotEmpty;
  io_fallback.configureCustomDataDir(path);
}

Directory resolveBaseDataDir() => io_fallback.resolveBaseDataDir();

Future<String?> readPreferenceString(String key) async {
  if (_useCustomDataDir) {
    return io_fallback.readPreferenceString(key);
  }
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(key);
}

Future<void> writePreferenceString(String key, String value) async {
  if (_useCustomDataDir) {
    return io_fallback.writePreferenceString(key, value);
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, value);
}

Future<Directory> getAppDocumentsDirectory() async {
  if (_useCustomDataDir) {
    return io_fallback.getAppDocumentsDirectory();
  }
  return getApplicationDocumentsDirectory();
}

Future<Directory> getAppSupportDirectory() async {
  if (_useCustomDataDir) {
    return io_fallback.getAppSupportDirectory();
  }
  return getApplicationSupportDirectory();
}

Future<Directory> getAppTemporaryDirectory() async {
  if (_useCustomDataDir) {
    return io_fallback.getAppTemporaryDirectory();
  }
  return getTemporaryDirectory();
}

Future<Uint8List?> loadAssetBytes(String assetPath) async {
  try {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return io_fallback.loadAssetBytes(assetPath);
  }
}

void evictAsset(String assetPath) {
  try {
    rootBundle.evict(assetPath);
  } catch (_) {}
}
