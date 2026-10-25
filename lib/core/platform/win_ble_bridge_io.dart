import 'dart:async';
import 'dart:typed_data';

class BleDevice {
  final String address;
  final String name;
  final String rssi;

  BleDevice({
    required this.address,
    required this.name,
    this.rssi = '',
  });
}

class WinServer {
  static Future<String> path({String? fileName}) async => '';
}

class WinBle {
  static Future<void> initialize({
    required String serverPath,
    bool enableLog = false,
  }) async {
    throw UnsupportedError('WinBle is only supported on Windows');
  }

  static Stream<BleDevice> get scanStream => const Stream.empty();

  static void startScanning() {}
  static void stopScanning() {}

  static Future<void> connect(String address) async {}
  static Future<void> disconnect(String address) async {}

  static Future<List<dynamic>> discoverServices(String address) async =>
      const [];

  static Stream<bool> connectionStreamOf(String address) =>
      const Stream.empty();

  static Future<void> subscribeToCharacteristic({
    required String address,
    required String serviceId,
    required String characteristicId,
  }) async {}

  static Stream<dynamic> get characteristicValueStream => const Stream.empty();

  static Future<void> write({
    required String address,
    required String service,
    required String characteristic,
    required Uint8List data,
    required bool writeWithResponse,
  }) async {}
}
