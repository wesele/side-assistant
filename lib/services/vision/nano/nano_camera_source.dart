import 'dart:async';
import 'dart:io';
import '../../../core/models/app_settings.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/storage_bridge.dart';
import '../capture_source.dart';
import 'nano_ble_driver.dart';
import 'nano_commands.dart';
import 'nano_datalink.dart';
import 'nano_media_client.dart';
import 'nano_wifi_driver.dart';

class NanoCameraSource implements CaptureSource {
  AppSettings settings;
  final NanoBleDriver bleDriver;
  void Function(bool isCapturing)? onCaptureStateChanged;
  bool _isCapturing = false;

  NanoCameraSource({
    required this.settings,
    NanoBleDriver? bleDriver,
    this.onCaptureStateChanged,
  }) : bleDriver = bleDriver ?? NanoBleDriver();

  @override
  bool get isOpen => bleDriver.isConnected;
  bool get isConnecting => bleDriver.isConnecting;
  bool get isCapturing => _isCapturing;
  int get batteryPercent => bleDriver.batteryPercent;
  bool get isCharging => bleDriver.isCharging;

  @override
  Future<bool> ensureOpen() async {
    if (isOpen) return true;
    if (isConnecting) return false;

    String? targetAddr = settings.nanoBleAddress.trim();
    if (targetAddr.isEmpty) {
      debugPrint('[NanoCameraSource] 未配置 Nano 蓝牙地址，开始自动扫描...');
      targetAddr = await bleDriver.scanForNano();
      if (targetAddr != null && targetAddr.isNotEmpty) {
        settings.nanoBleAddress = targetAddr;
        unawaited(settings.save());
      }
    }

    if (targetAddr == null || targetAddr.isEmpty) {
      throw Exception('未找到 DJI Osmo Nano 蓝牙设备，请确保相机已开机且在附近');
    }

    final connected = await bleDriver.connect(targetAddr);
    if (!connected) {
      throw Exception('无法连接 DJI Osmo Nano 蓝牙 ($targetAddr)');
    }

    // 若本地未配置 Wi-Fi 凭证，尝试通过 BLE 读取并持久化
    if (settings.nanoSsid.isEmpty || settings.nanoPassword.isEmpty) {
      try {
        final (ssid, pwd) = await bleDriver.readWifiCredentials();
        if (ssid.isNotEmpty && pwd.isNotEmpty) {
          settings.nanoSsid = ssid;
          settings.nanoPassword = pwd;
          await settings.save();
        }
      } catch (e) {
        debugPrint('[NanoCameraSource] 从 BLE 协商 Wi-Fi 凭据警告: $e');
      }
    }

    return true;
  }

  @override
  Future<CameraCaptureResult> capturePhoto() async {
    if (_isCapturing) {
      throw Exception('Nano 正在执行抓拍中，请勿重复触发');
    }

    _isCapturing = true;
    onCaptureStateChanged?.call(true);
    NanoDatalink? datalink;
    String targetIface = '';

    try {
      // 1. 确保蓝牙连接并发送唤醒与 SoftAP 拉起帧（支持从低功耗休眠瞬间唤醒）
      final opened = await ensureOpen();
      if (!opened) {
        throw Exception('Nano 蓝牙未连接');
      }

      bleDriver.send(sessionWake());
      bleDriver.send(session5310());
      await Future.delayed(const Duration(milliseconds: 300));

      // 2. 解析网卡与 Wi-Fi 凭证 (若本地未缓存则即时通过蓝牙自动获取)
      targetIface = await NanoWifiDriver.resolveInterface(settings.nanoWlanInterface);
      String ssid = settings.nanoSsid.trim();
      String password = settings.nanoPassword.trim();
      if (ssid.isEmpty || password.isEmpty) {
        debugPrint('[NanoCameraSource] 本地无 Wi-Fi 凭证，正在从蓝牙自动读取...');
        final (newSsid, newPwd) = await bleDriver.readWifiCredentials();
        if (newSsid.isNotEmpty && newPwd.isNotEmpty) {
          ssid = newSsid;
          password = newPwd;
          settings.nanoSsid = ssid;
          settings.nanoPassword = password;
          unawaited(settings.save());
        }
      }
      if (ssid.isEmpty || password.isEmpty) {
        throw Exception('未能自动获取 Nano Wi-Fi 凭证，请确保相机已开机点亮并在屏幕上确认允许连接');
      }

      // 3. 关联 SoftAP
      debugPrint('[NanoCameraSource] 开始关联 Nano SoftAP ($ssid) 网卡: $targetIface');
      final wlanIp = await NanoWifiDriver.connectSoftAp(
        iface: targetIface,
        ssid: ssid,
        password: password,
      );

      // 4. 建立 DUML 数据链路
      debugPrint('[NanoCameraSource] 开始建立 DUML 链路 (本地绑定 IP: $wlanIp)');
      datalink = NanoDatalink(host: '192.168.2.1', port: 9004);
      final ok = await datalink.connect(localIp: wlanIp);
      if (!ok) {
        throw Exception('DUML 数据链路握手失败');
      }

      // 5. 确保为 Photo 拍照模式 (0x05)
      datalink.sendCommand(setShootingMode(0x05));
      await Future.delayed(const Duration(milliseconds: 200));

      // 6. 获取拍照前媒体基线清单
      final mediaClient = NanoMediaClient(datalink);
      final baselineFiles = await mediaClient.listMedia();
      final baselinePaths = baselineFiles.map((f) => f.path).toSet();
      debugPrint('[NanoCameraSource] 基线媒体数量: ${baselineFiles.length}');

      // 7. 发送快门拍照指令
      debugPrint('[NanoCameraSource] 触发快门...');
      datalink.sendCommand(shootPhoto());
      try {
        await datalink.waitForFrame(0x0201, timeout: const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[NanoCameraSource] 快门回执超时 (相机可能已拍摄): $e');
      }

      // 等待相机存储落盘与媒体库解锁 (约 1.2 秒)
      await Future.delayed(const Duration(milliseconds: 1200));

      // 8. 轮询清单检索最新照片
      NanoMediaFile? newPhoto;
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        final currentFiles = await mediaClient.listMedia(timeout: const Duration(seconds: 3));
        final fresh = currentFiles.where((f) => f.isPhoto && !baselinePaths.contains(f.path)).toList();
        if (fresh.isNotEmpty) {
          fresh.sort((a, b) => a.name.compareTo(b.name));
          newPhoto = fresh.last;
          break;
        } else if (currentFiles.isNotEmpty && baselinePaths.isEmpty) {
          final photos = currentFiles.where((f) => f.isPhoto).toList();
          if (photos.isNotEmpty) {
            photos.sort((a, b) => a.name.compareTo(b.name));
            newPhoto = photos.last;
            break;
          }
        }
        await Future.delayed(const Duration(milliseconds: 400));
      }

      if (newPhoto == null) {
        throw Exception('拍照完成，但在相机媒体清单中未能检测到新生成的照片文件');
      }

      debugPrint('[NanoCameraSource] 发现新照片: ${newPhoto.path}，正在通过 HTTP 取回...');

      // 9. HTTP 下载照片
      final imageBytes = await NanoMediaClient.downloadPhotoBytes(
        host: '192.168.2.1',
        file: newPhoto,
      );

      Directory tempDir;
      try {
        tempDir = await StorageBridge.getAppTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      final localFile = File('${tempDir.path}/${newPhoto.name}');
      await localFile.writeAsBytes(imageBytes);
      debugPrint('[NanoCameraSource] 照片下载成功: ${localFile.path} (${imageBytes.length} 字节)');

      return CameraCaptureResult(
        imageBytes: imageBytes,
        filePath: localFile.path,
        isSimulated: false,
      );
    } finally {
      // 10. 严格断开 Wi-Fi 与数据链路释放资源
      if (datalink != null) {
        await datalink.close();
      }
      if (targetIface.isNotEmpty) {
        await NanoWifiDriver.disconnectSoftAp(targetIface);
      }
      _isCapturing = false;
      onCaptureStateChanged?.call(false);
    }
  }

  @override
  Future<void> close() async {
    await bleDriver.disconnect();
  }

  @override
  void dispose() {
    close();
  }
}
