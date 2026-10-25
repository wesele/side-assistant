import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/storage_bridge.dart';

class NanoWifiDriver {
  static const String cameraHost = '192.168.2.1';

  static Future<ProcessResult> runNetsh(List<String> args, {Duration timeout = const Duration(seconds: 15)}) async {
    return Process.run('netsh', args).timeout(timeout);
  }

  static String decodeProcessOutput(ProcessResult res) {
    final stdoutBytes = res.stdout is List<int> ? res.stdout as List<int> : utf8.encode(res.stdout.toString());
    final stderrBytes = res.stderr is List<int> ? res.stderr as List<int> : utf8.encode(res.stderr.toString());
    final allBytes = [...stdoutBytes, ...stderrBytes];
    try {
      return utf8.decode(allBytes);
    } catch (_) {
      try {
        return systemEncoding.decode(allBytes);
      } catch (_) {
        return String.fromCharCodes(allBytes);
      }
    }
  }

  /// 获取系统上所有 WLAN 接口名称列表（例如 ['WLAN', 'WLAN 2']）
  static Future<List<String>> getWlanInterfaces() async {
    if (!Platform.isWindows ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return [];
    }
    try {
      final res = await runNetsh(['wlan', 'show', 'interfaces']);
      if (res.exitCode != 0) return [];
      final text = decodeProcessOutput(res);
      final names = <String>[];
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        final colonIdx = line.indexOf(':');
        if (colonIdx != -1) {
          final val = line.substring(colonIdx + 1).trim();
          if (RegExp(r'^WLAN(?:\s*\d+)?$', caseSensitive: false).hasMatch(val)) {
            if (!names.contains(val)) {
              names.add(val);
            }
          }
        }
      }
      return names;
    } catch (e) {
      debugPrint('[NanoWifiDriver] 获取 WLAN 接口异常: $e');
      return [];
    }
  }

  /// 根据配置与检测情况解析目标网卡名称
  static Future<String> resolveInterface(String configuredInterface) async {
    final ifaces = await getWlanInterfaces();
    if (ifaces.isEmpty) return 'WLAN';

    if (configuredInterface.isNotEmpty && configuredInterface.toLowerCase() != 'auto') {
      for (final iface in ifaces) {
        if (iface.toLowerCase() == configuredInterface.toLowerCase()) {
          return iface;
        }
      }
    }

    // 自动策略：优先选择 WLAN 2（副网卡免断网导图），其次主网卡 WLAN
    for (final iface in ifaces) {
      if (iface.toUpperCase().contains('WLAN 2') || iface.toUpperCase().contains('WLAN2')) {
        return iface;
      }
    }
    for (final iface in ifaces) {
      if (iface.toUpperCase() == 'WLAN') {
        return iface;
      }
    }
    return ifaces.first;
  }

  static String generateProfileXml(String ssid, String password) {
    final escapedSsid = ssid.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final escapedKey = password.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    return '''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedSsid</name>
  <SSIDConfig><SSID><name>$escapedSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$escapedKey</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>''';
  }

  /// 获取指定网卡上被分配的 192.168.2.x IP
  static Future<String> getInterfaceIp(String iface) async {
    try {
      final res = await runNetsh(['interface', 'ipv4', 'show', 'addresses', iface]);
      if (res.exitCode != 0) return '';
      final text = decodeProcessOutput(res);
      final match = RegExp(r'\b(192\.168\.2\.\d{1,3})\b').firstMatch(text);
      return match != null ? match.group(1)! : '';
    } catch (_) {
      return '';
    }
  }

  /// 关联并连接目标 SoftAP，直到获取 192.168.2.x IP
  static Future<String> connectSoftAp({
    required String iface,
    required String ssid,
    required String password,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    Directory tempDir;
    try {
      tempDir = await StorageBridge.getAppTemporaryDirectory();
    } catch (_) {
      tempDir = Directory.systemTemp;
    }
    final profileFile = File('${tempDir.path}/nano_${DateTime.now().millisecondsSinceEpoch}.xml');
    try {
      await profileFile.writeAsString(generateProfileXml(ssid, password));
      final addRes = await runNetsh([
        'wlan',
        'add',
        'profile',
        'filename=${profileFile.path}',
        'interface=$iface',
        'user=current',
      ]);
      if (addRes.exitCode != 0) {
        throw Exception('导入 Wi-Fi profile 失败: ${decodeProcessOutput(addRes)}');
      }

      final connRes = await runNetsh([
        'wlan',
        'connect',
        'name=$ssid',
        'ssid=$ssid',
        'interface=$iface',
      ]);
      if (connRes.exitCode != 0) {
        throw Exception('连接 Wi-Fi 热点 $ssid 失败: ${decodeProcessOutput(connRes)}');
      }

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final ip = await getInterfaceIp(iface);
        if (ip.isNotEmpty) {
          debugPrint('[NanoWifiDriver] 成功加入 $ssid (网卡: $iface, 分配 IP: $ip)');
          return ip;
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
      throw TimeoutException('连接 SoftAP $ssid 超时，未能在指定时间内获取到 192.168.2.x 地址');
    } finally {
      if (profileFile.existsSync()) {
        try {
          profileFile.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// 断开指定网卡的 Wi-Fi 连接
  static Future<bool> disconnectSoftAp(String iface) async {
    try {
      final res = await runNetsh(['wlan', 'disconnect', 'interface=$iface']);
      return res.exitCode == 0;
    } catch (e) {
      debugPrint('[NanoWifiDriver] 断开 Wi-Fi 异常: $e');
      return false;
    }
  }
}
