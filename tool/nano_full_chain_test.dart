// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/vision/nano/nano_ble_driver.dart';
import 'package:side_assistant/services/vision/nano/nano_wifi_driver.dart';
import 'package:side_assistant/services/vision/nano/nano_datalink.dart';
import 'package:side_assistant/services/vision/nano/nano_media_client.dart';
import 'package:side_assistant/services/vision/nano/nano_commands.dart';

class TimingRecord {
  final String step;
  final double seconds;
  final bool success;
  final String details;

  TimingRecord(this.step, this.seconds, this.success, this.details);
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  test('DJI Osmo Nano 纯 Dart 架构硬件全链条自动化实机抓拍测试', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = _RealHttpOverrides();

    print('======================================================================');
    print('          DJI Osmo Nano 纯 Dart 架构硬件全链条自动化实机测试          ');
    print('======================================================================');

    final records = <TimingRecord>[];
    final totalSw = Stopwatch()..start();

    Future<T> measureStep<T>(
      String name,
      Future<T> Function() action, {
      String Function(T result)? detailFormatter,
    }) async {
      final sw = Stopwatch()..start();
      print('\n>>> [${DateTime.now().toIso8601String().substring(11, 19)}] 开始: $name');
      try {
        final res = await action();
        sw.stop();
        final dt = sw.elapsedMilliseconds / 1000.0;
        final details = detailFormatter?.call(res) ?? '';
        records.add(TimingRecord(name, dt, true, details));
        print('<<< [${DateTime.now().toIso8601String().substring(11, 19)}] 完成: $name | 耗时: ${dt.toStringAsFixed(3)}s | 状态: 成功 $details');
        return res;
      } catch (e) {
        sw.stop();
        final dt = sw.elapsedMilliseconds / 1000.0;
        records.add(TimingRecord(name, dt, false, e.toString()));
        print('<<< [${DateTime.now().toIso8601String().substring(11, 19)}] 完成: $name | 耗时: ${dt.toStringAsFixed(3)}s | 状态: 失败 ($e)');
        rethrow;
      }
    }

    final ble = NanoBleDriver(
      onLog: (m) => print('  [BLE Log] $m'),
    );

    NanoDatalink? datalink;
    String targetIface = '';
    String targetAddr = '';
    String ssid = '';
    String password = '';
    String assignedIp = '';
    File? savedPhotoFile;

    try {
      // 步骤 1：扫描并连接蓝牙
      await measureStep('1. 扫描并连接 DJI Osmo Nano 蓝牙', () async {
        targetAddr = await ble.scanForNano(timeout: const Duration(seconds: 5)) ?? '';
        if (targetAddr.isEmpty) {
          targetAddr = '8C:58:23:8F:0B:57'; // 真机已知回退
        }
        final ok = await ble.connect(targetAddr, timeout: const Duration(seconds: 10));
        if (!ok) throw Exception('蓝牙连接失败');
        return targetAddr;
      }, detailFormatter: (addr) => 'MAC: $addr, 电量: ${ble.batteryPercent >= 0 ? "${ble.batteryPercent}%" : "就绪"}');

      // 步骤 2：自动拉起 SoftAP 并获取 Wi-Fi 凭证
      await measureStep('2. 自动拉起 SoftAP 并协商热点凭证', () async {
        final creds = await ble.readWifiCredentials(timeout: const Duration(seconds: 8));
        ssid = creds.$1;
        password = creds.$2;
        if (ssid.isEmpty || password.isEmpty) {
          throw Exception('未能获取有效 Wi-Fi 凭据');
        }
        return creds;
      }, detailFormatter: (c) => 'SSID: "${c.$1}", Password: "${c.$2.replaceAll(RegExp(r'.'), '*')}"');

      // 步骤 3：绑定网卡并关联 Nano SoftAP
      await measureStep('3. WLAN 2 网卡关联 SoftAP 并获取 IP', () async {
        targetIface = await NanoWifiDriver.resolveInterface('auto');
        assignedIp = await NanoWifiDriver.connectSoftAp(
          iface: targetIface,
          ssid: ssid,
          password: password,
          timeout: const Duration(seconds: 20),
        );
        return assignedIp;
      }, detailFormatter: (ip) => '网卡: $targetIface, 分配 IP: $ip');

      // 步骤 4：建立 DUML 数据链路握手
      await measureStep('4. 建立 TCP 7001 Poke 与 UDP 9004 DUML 数据链路', () async {
        datalink = NanoDatalink(
          host: '192.168.2.1',
          port: 9004,
          onLog: (m) => print('  [Datalink Log] $m'),
        );
        final ok = await datalink!.connect(localIp: assignedIp);
        if (!ok) throw Exception('DUML 握手失败');
        return ok;
      }, detailFormatter: (_) => 'UDP 链路握手成功，40Hz ACK 泵与 1Hz 保活泵已开启');

      // 步骤 5：模式校验与基线清单
      final mediaClient = NanoMediaClient(datalink!);
      late Set<String> baselinePaths;
      await measureStep('5. 切换 Photo 拍照模式并获取基线媒体清单', () async {
        datalink!.sendCommand(setShootingMode(0x05));
        await Future.delayed(const Duration(milliseconds: 200));
        final files = await mediaClient.listMedia();
        baselinePaths = files.map((f) => f.path).toSet();
        return files.length;
      }, detailFormatter: (len) => '基线媒体数: $len');

      // 步骤 6：触发快门抓拍
      await measureStep('6. 触发快门指令 (0x02/0x01 [01])', () async {
        datalink!.sendCommand(shootPhoto());
        try {
          await datalink!.waitForFrame(0x0201, timeout: const Duration(seconds: 3));
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 1200)); // 等待存储落盘
      });

      // 步骤 7：轮询检索最新生成的照片文件
      late NanoMediaFile latestPhoto;
      await measureStep('7. 轮询媒体清单检索新照片文件', () async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        NanoMediaFile? found;
        while (DateTime.now().isBefore(deadline)) {
          final currentFiles = await mediaClient.listMedia(timeout: const Duration(seconds: 3));
          print('  [Poll] listMedia 返回 ${currentFiles.length} 个文件 (基线: ${baselinePaths.length})');
          if (currentFiles.isNotEmpty) {
            print('  [Poll] 最新文件: ${currentFiles.first.path} (isPhoto: ${currentFiles.first.isPhoto})');
          }
          final fresh = currentFiles.where((f) => f.isPhoto && !baselinePaths.contains(f.path)).toList();
          if (fresh.isNotEmpty) {
            fresh.sort((a, b) => a.name.compareTo(b.name));
            found = fresh.last;
            break;
          } else if (currentFiles.isNotEmpty && baselinePaths.isEmpty) {
            final photos = currentFiles.where((f) => f.isPhoto).toList();
            if (photos.isNotEmpty) {
              photos.sort((a, b) => a.name.compareTo(b.name));
              found = photos.last;
              break;
            }
          }
          await Future.delayed(const Duration(milliseconds: 400));
        }
        if (found == null) throw Exception('未能检测到新拍摄的照片文件');
        latestPhoto = found;
        return latestPhoto;
      }, detailFormatter: (p) => '发现新文件: ${p.path} (大小: ${p.sizeBytes} 字节)');

      // 步骤 8：HTTP 下载照片并校验完整性
      await measureStep('8. 通过 HTTP 取回照片并做完整性校验', () async {
        final bytes = await NanoMediaClient.downloadPhotoBytes(
          host: '192.168.2.1',
          file: latestPhoto,
          timeout: const Duration(seconds: 15),
        );
        final outDir = Directory('NanoTest/captures');
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        final dest = File('${outDir.path}/${latestPhoto.name}');
        await dest.writeAsBytes(bytes);
        savedPhotoFile = dest;
        final isJpeg = bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
        if (!isJpeg) throw Exception('下载文件非合法 JPEG 头');
        return (dest.path, bytes.length, isJpeg);
      }, detailFormatter: (r) => '保存至: ${r.$1} (${(r.$2 / 1024.0).toStringAsFixed(1)} KB, JPEG魔数有效: ${r.$3})');

    } finally {
      // 步骤 9：断开 Wi-Fi 释放网络资源
      if (datalink != null) {
        await datalink!.close();
      }
      if (targetIface.isNotEmpty) {
        await measureStep('9. 断开 WLAN 2 Wi-Fi 释放连接', () async {
          await NanoWifiDriver.disconnectSoftAp(targetIface);
        });
      }

      // 步骤 10：安全断开蓝牙连接
      await measureStep('10. 安全断开 Nano 蓝牙连接', () async {
        await ble.disconnect();
      });
    }

    totalSw.stop();
    final totalSec = totalSw.elapsedMilliseconds / 1000.0;

    print('\n' + '=' * 88);
    print('                 DJI Osmo Nano 纯 Dart 全链条测试结果汇总');
    print('=' * 88);
    print('${"步骤".padRight(36)} | ${"耗时".padLeft(8)} | ${"状态".padRight(4)} | 详细说明');
    print('-' * 88);
    for (final r in records) {
      print('${r.step.padRight(36)} | ${(r.seconds.toStringAsFixed(3) + "s").padLeft(8)} | ${r.success ? "成功" : "失败"} | ${r.details}');
    }
    print('-' * 88);
    print('${"总计耗时".padRight(36)} | ${(totalSec.toStringAsFixed(3) + "s").padLeft(8)} |');
    print('=' * 88);

    expect(savedPhotoFile != null && savedPhotoFile!.existsSync(), isTrue);
    print('\n🎉 全链条实机自动化测试彻底成功！');
    print('最新抓拍并验证合法的照片位于: ${savedPhotoFile!.absolute.path}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
