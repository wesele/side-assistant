import '../../core/ports/camera_port.dart';
import 'dart:async';
import 'dart:io';

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/camera_plugin_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import 'android_camera_bridge.dart';
import 'capture/camera_capture_source.dart';
import 'capture/camera_source_registry.dart';
import 'capture/linux_v4l2_capture_source.dart';
import 'capture/local_camera_capture_source.dart';
import 'capture/mock_camera_capture_source.dart';
import 'capture/nano_wifi_capture_source.dart';
import 'nano/nano_ble_driver.dart';
import 'nano/nano_camera_source.dart';
import 'nano/nano_wifi_driver.dart';

export 'android_camera_bridge.dart' show CameraResolution;
export 'capture/camera_capture_source.dart';
export 'capture/camera_source_registry.dart';
export 'capture/linux_v4l2_capture_source.dart';
export 'capture/local_camera_capture_source.dart';
export 'capture/mock_camera_capture_source.dart';
export 'capture/nano_wifi_capture_source.dart';
export 'nano/nano_camera_source.dart';

/// DJI Osmo Nano 链路诊断测试结果
class NanoLinkTestResult {
  final bool success;
  final String message;
  final String? bleAddress;
  final int batteryPercent;
  final String? ssid;
  final String? ip;

  const NanoLinkTestResult({
    required this.success,
    required this.message,
    this.bleAddress,
    this.batteryPercent = -1,
    this.ssid,
    this.ip,
  });
}

/// 摄像头管理服务（Facade 门面与 Strategy 策略选择器）
///
/// 基于 [CameraSourceRegistry] 统一管理不同形态抓拍硬件源（本地镜头 / DJI Osmo Nano / Linux V4L2 / Mock），
/// 负责空闲超时自动休眠释放、保活调度与统一抓拍入口。
class CameraService implements CameraPort {
  AppSettings settings;
  final CameraSourceRegistry _registry = CameraSourceRegistry();
  Timer? _idleCloseTimer;
  bool _isStreaming = false;

  CameraService({
    required this.settings,
    CameraCaptureSource? localSource,
    CameraCaptureSource? nanoSource,
  }) {
    _registry.register(
      localSource ?? LocalCameraCaptureSource(settings: settings),
    );
    _registry.register(
      nanoSource ?? NanoWifiCaptureSource(settings: settings),
    );
    _registry.register(LinuxV4L2CaptureSource(settings: settings));
    _registry.register(MockCameraCaptureSource());
  }

  /// 获取策略注册表实例
  CameraSourceRegistry get registry => _registry;

  /// 更新全局配置并同步至所有已注册策略
  void updateSettings(AppSettings newSettings) {
    settings = newSettings;
    final local = _registry.getSource(CameraSourceType.localDevice);
    if (local is LocalCameraCaptureSource) {
      local.settings = newSettings;
    }
    final nano = _registry.getSource(CameraSourceType.nanoWifi);
    if (nano is NanoWifiCaptureSource) {
      nano.settings = newSettings;
    }
    final linux = _registry.getSource(CameraSourceType.linuxV4l2);
    if (linux is LinuxV4L2CaptureSource) {
      linux.settings = newSettings;
    }
    if (settings.captureSource == AppConstants.captureSourceNano) {
      _idleCloseTimer?.cancel();
      _idleCloseTimer = null;
    }
  }

  /// 局部热重载：更新视觉与摄像头配置，不影响 ASR 与音频
  @override
  void applyConfig(VisionConfig config) {
    settings.vision = config;
    updateSettings(settings);
  }

  /// 当前激活的捕获源策略
  CameraCaptureSource get activeSource {
    if (settings.captureSource == AppConstants.captureSourceNano) {
      return _registry.getSource(CameraSourceType.nanoWifi)!;
    }
    if (Platform.isLinux && !isRunningInFlutterTest) {
      final v4l2 = _registry.getSource(CameraSourceType.linuxV4l2);
      if (v4l2 != null && v4l2.isAvailable) return v4l2;
    }
    return _registry.getSource(CameraSourceType.localDevice) ??
        _registry.getSource(CameraSourceType.mock)!;
  }

  /// 当前激活捕获源类型
  CameraSourceType get currentSourceType => activeSource.type;

  /// 切换抓拍源策略
  Future<void> switchSource(dynamic source) async {
    if (source is CameraSourceType) {
      switch (source) {
        case CameraSourceType.nanoWifi:
          settings.captureSource = AppConstants.captureSourceNano;
          break;
        case CameraSourceType.localDevice:
        default:
          settings.captureSource = AppConstants.captureSourceLocal;
          break;
      }
    } else if (source is String) {
      settings.captureSource = source;
    }
    updateSettings(settings);
  }

  /// 保持存量属性访问
  LocalCameraCaptureSource get localSource =>
      _registry.getSource(CameraSourceType.localDevice)!
          as LocalCameraCaptureSource;

  NanoWifiCaptureSource get nanoSource =>
      _registry.getSource(CameraSourceType.nanoWifi)! as NanoWifiCaptureSource;

  @override
  bool get isCameraOpen => activeSource.isOpen;
  bool get isStreaming => _isStreaming;

  CameraController? get controller {
    final local = _registry.getSource(CameraSourceType.localDevice);
    if (local is LocalCameraCaptureSource) {
      return local.controller;
    }
    return null;
  }

  CameraDescription? get currentSelectedCamera {
    final local = _registry.getSource(CameraSourceType.localDevice);
    if (local is LocalCameraCaptureSource) {
      return local.currentSelectedCamera;
    }
    return null;
  }

  bool get isIdleTimerRunning =>
      _idleCloseTimer != null && _idleCloseTimer!.isActive;

  /// 重置空闲超时关闭计时器（每次拍照或触发视觉意图时调用）
  void _resetIdleTimer() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    // Nano 相机模式下保持蓝牙常连，空闲关闭配置无效
    if (settings.captureSource == AppConstants.captureSourceNano) {
      return;
    }
    if (settings.cameraKeepAliveMinutes <= 0) {
      return;
    }
    final minutes = settings.cameraKeepAliveMinutes.clamp(1, 10);
    _idleCloseTimer = Timer(Duration(minutes: minutes), () {
      debugPrint('[CameraService] 拍照源已空闲 $minutes 分钟，自动关闭释放资源以保护隐私与电量');
      closeCamera();
    });
  }

  /// 显式刷新空闲保活计时器
  void keepAlive([int? minutes]) {
    if (minutes != null && minutes > 0) {
      settings.cameraKeepAliveMinutes = minutes;
    }
    _resetIdleTimer();
  }

  @visibleForTesting
  void resetIdleTimerForTest() => _resetIdleTimer();

  /// 初始化或复用已开启的拍照源
  Future<bool> ensureCameraOpen() async {
    final ok = await activeSource.ensureOpen();
    if (ok) {
      _resetIdleTimer();
    }
    return ok;
  }

  /// 直接单帧抓拍入口
  Future<CameraCaptureResult> takePictureDirect({
    CameraResolution? resolution,
  }) async {
    try {
      final result = await activeSource.captureFrame(resolution: resolution);
      return result;
    } finally {
      if (settings.captureSource == AppConstants.captureSourceNano) {
        debugPrint('[CameraService] Nano 相机模式：保持蓝牙连接，不执行空闲关闭');
      } else if (settings.cameraKeepAliveMinutes <= 0) {
        debugPrint('[CameraService] 拍照源空闲关闭设置为0分钟，拍完立即关闭');
        await closeCamera();
      } else {
        _resetIdleTimer();
      }
    }
  }

  /// 执行画面抓拍：委托给当前 activeSource 执行
  @override
  Future<CameraCaptureResult> capturePhoto() async {
    return takePictureDirect();
  }

  /// 启动实时视频预览流
  Future<Stream<CameraFrame>?> startStreaming() async {
    final opened = await ensureCameraOpen();
    if (!opened) return null;
    _isStreaming = true;
    return activeSource.previewStream;
  }

  /// 停止实时视频预览流
  Future<void> stopStreaming() async {
    _isStreaming = false;
  }

  /// 释放并关闭当前拍照源
  Future<void> closeCamera() async {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _isStreaming = false;
    await activeSource.close();
  }

  /// 销毁服务
  @override
  void dispose() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _isStreaming = false;
    unawaited(_registry.disposeAll());
  }

  // ==========================================
  // Platform Driver & Hardware Facade Methods
  // ==========================================

  /// 获取目标镜头支持的所有拍照分辨率（从大到小排序）
  static Future<List<CameraResolution>> getAvailableResolutions({
    String lensDirection = 'back',
    int? cameraId,
  }) async {
    return await AndroidCameraBridge.getSupportedResolutions(
      lensDirection: lensDirection,
    );
  }

  /// 获取系统可用的 WLAN 网卡接口列表（如 ['WLAN', 'WLAN 2']）
  static Future<List<String>> getWlanInterfaces() async {
    return await NanoWifiDriver.getWlanInterfaces();
  }

  /// 根据配置与检测情况解析目标网卡名称
  static Future<String> resolveWlanInterface(String configuredInterface) async {
    return await NanoWifiDriver.resolveInterface(configuredInterface);
  }

  /// 连接 DJI Osmo Nano 发射的 Wi-Fi 热点 (SoftAP)
  static Future<String?> connectNanoSoftAp({
    required String iface,
    required String ssid,
    required String password,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return await NanoWifiDriver.connectSoftAp(
      iface: iface,
      ssid: ssid,
      password: password,
      timeout: timeout,
    );
  }

  /// 断开与 DJI Osmo Nano SoftAP 的 Wi-Fi 连接
  static Future<void> disconnectNanoSoftAp(String iface) async {
    await NanoWifiDriver.disconnectSoftAp(iface);
  }

  /// 检查当前是否已获得相机权限
  static Future<bool> hasCameraPermission() async {
    return await AndroidCameraBridge.hasPermission();
  }

  /// 请求相机权限
  static Future<bool> requestCameraPermission() async {
    return await AndroidCameraBridge.requestPermission();
  }

  /// 检查并请求相机权限（若未授予且不再弹窗则引导打开系统设置）
  static Future<bool> checkAndRequestPermissions() async {
    final granted = await AndroidCameraBridge.requestPermission();
    if (!granted) {
      await AndroidCameraBridge.openAppSettings();
    }
    return granted;
  }

  /// 打开系统设置中的本应用详情页
  static Future<void> openAppSettings() async {
    await AndroidCameraBridge.openAppSettings();
  }

  /// 测试 DJI Osmo Nano 链路（BLE 扫描/连接、凭证读取、SoftAP 临时入网测试）
  static Future<NanoLinkTestResult> testNanoLink({
    required AppSettings settings,
    String? bleAddressOverride,
    required String wlanInterface,
    void Function(String status)? onProgress,
    void Function(String bleAddress)? onBleAddressFound,
  }) async {
    onProgress?.call('正在启动 Nano 链路检测...');
    final bleDriver = NanoBleDriver();
    try {
      String addr = (bleAddressOverride ?? '').trim();
      if (addr.isEmpty) {
        onProgress?.call('正在扫描附近的 DJI Osmo Nano...');
        final found =
            await bleDriver.scanForNano(timeout: const Duration(seconds: 6));
        if (found == null) {
          throw Exception('未扫描到目标 Nano 蓝牙设备，请确保相机已开机且在附近');
        }
        addr = found;
        onBleAddressFound?.call(addr);
      }

      onProgress?.call('正在连接 Nano 蓝牙 ($addr)...');
      final connected = await bleDriver.connect(addr);
      if (!connected) {
        throw Exception('蓝牙 GATT 连接失败');
      }

      final battery = bleDriver.batteryPercent;
      onProgress?.call(
          '蓝牙连接成功 (电量: ${battery >= 0 ? '$battery%' : '就绪'})，正在尝试唤醒与协商凭据...');

      String currentSsid = settings.nanoSsid;
      String currentPassword = settings.nanoPassword;

      try {
        final (ssid, pwd) = await bleDriver.readWifiCredentials(
            timeout: const Duration(seconds: 8));
        if (ssid.isNotEmpty && pwd.isNotEmpty) {
          currentSsid = ssid;
          currentPassword = pwd;
          settings.nanoSsid = ssid;
          settings.nanoPassword = pwd;
          await settings.save();
        }
      } catch (e) {
        debugPrint('[CameraService] 自动读取 Wi-Fi 凭证提示: $e');
      }

      if (currentSsid.isNotEmpty && currentPassword.isNotEmpty) {
        final targetIface =
            await NanoWifiDriver.resolveInterface(wlanInterface);
        onProgress?.call('已自动获取 Wi-Fi 凭证 ($currentSsid)，正在测试连接与入网...');
        final ip = await NanoWifiDriver.connectSoftAp(
          iface: targetIface,
          ssid: currentSsid,
          password: currentPassword,
          timeout: const Duration(seconds: 15),
        );
        await NanoWifiDriver.disconnectSoftAp(targetIface);
        final currentBattery = bleDriver.batteryPercent;
        final msg =
            '✅ 测试通过！蓝牙与 Wi-Fi 链路畅通 (电量: ${currentBattery >= 0 ? '$currentBattery%' : '就绪'}, 自动获取热点: $currentSsid, 网卡: $targetIface, 分配 IP: $ip)';
        onProgress?.call(msg);
        return NanoLinkTestResult(
          success: true,
          message: msg,
          bleAddress: addr,
          batteryPercent: currentBattery,
          ssid: currentSsid,
          ip: ip,
        );
      } else {
        final msg =
            '✅ 蓝牙测试通过 (电量: ${battery >= 0 ? '$battery%' : '就绪'})，未解锁 Wi-Fi 凭证，请确认相机亮屏并允许配对';
        onProgress?.call(msg);
        return NanoLinkTestResult(
          success: true,
          message: msg,
          bleAddress: addr,
          batteryPercent: battery,
        );
      }
    } catch (e) {
      final msg = '❌ 测试未通过: $e';
      onProgress?.call(msg);
      return NanoLinkTestResult(
        success: false,
        message: msg,
      );
    } finally {
      await bleDriver.disconnect();
    }
  }
}
