import 'dart:io';
import 'dart:typed_data';
import 'storage_bridge_io.dart'
    if (dart.library.ui) 'storage_bridge_flutter.dart' as impl;

class StorageBridge {
  StorageBridge._();

  static void configureCustomDataDir(String path) =>
      impl.configureCustomDataDir(path);

  static Directory resolveBaseDataDir() => impl.resolveBaseDataDir();

  static Future<String?> readPreferenceString(String key) =>
      impl.readPreferenceString(key);

  static Future<void> writePreferenceString(String key, String value) =>
      impl.writePreferenceString(key, value);

  static Future<Directory> getAppDocumentsDirectory() =>
      impl.getAppDocumentsDirectory();

  static Future<Directory> getAppSupportDirectory() =>
      impl.getAppSupportDirectory();

  static Future<Directory> getAppTemporaryDirectory() =>
      impl.getAppTemporaryDirectory();

  static Future<Uint8List?> loadAssetBytes(String assetPath) =>
      impl.loadAssetBytes(assetPath);

  static void evictAsset(String assetPath) => impl.evictAsset(assetPath);
}
