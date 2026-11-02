import 'dart:async';
import 'dart:io';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/win_ble_bridge.dart';
import 'duml_packet.dart';
import 'nano_commands.dart';

const String bleServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const String bleNotifyCharUuid = '0000fff4-0000-1000-8000-00805f9b34fb';
const String bleWriteCharUuid = '0000fff5-0000-1000-8000-00805f9b34fb';

class BleAssembler {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  List<DumlFrame> append(Uint8List data) {
    if (data.length > 4096 || _pending.length + data.length > 4096) {
      _pending.clear();
      if (data.length > 4096) return [];
    }
    _pending.add(data);
    final bytes = _pending.takeBytes();
    final out = <DumlFrame>[];
    int offset = 0;
    final n = bytes.length;

    while (n - offset >= 4) {
      if (bytes[offset] != 0x55 ||
          (bytes[offset + 2] >> 2) != 1 ||
          crc8(Uint8List.sublistView(bytes, offset, offset + 3)) !=
              bytes[offset + 3]) {
        offset++;
        continue;
      }
      final length = bytes[offset + 1] | ((bytes[offset + 2] & 3) << 8);
      if (length < 13) {
        offset++;
        continue;
      }
      if (n - offset < length) {
        break;
      }
      final end = offset + length;
      final checksum = bytes[end - 2] | (bytes[end - 1] << 8);
      if (crc16(Uint8List.sublistView(bytes, offset, end - 2)) == checksum) {
        out.add(
          DumlFrame(
            sender: bytes[offset + 4],
            receiver: bytes[offset + 5],
            seq: bytes[offset + 6] | (bytes[offset + 7] << 8),
            flags: bytes[offset + 8],
            cmdSet: bytes[offset + 9],
            cmdId: bytes[offset + 10],
            payload: Uint8List.fromList(
                Uint8List.sublistView(bytes, offset + 11, end - 2)),
          ),
        );
        offset = end;
        continue;
      }
      offset++;
    }
    if (offset < n) {
      _pending.add(Uint8List.sublistView(bytes, offset));
    }
    return out;
  }
}

class NanoBleDriver {
  void Function(String message)? onLog;
  void Function(int percent, bool isCharging)? onBatteryUpdate;

  bool _isBleInitialized = false;
  String _address = '';
  bool _isConnected = false;
  bool _isConnecting = false;
  int _batteryPercent = -1;
  bool _isCharging = false;

  final BleAssembler _assembler = BleAssembler();
  final List<DumlFrame> _writeQueue = [];
  Timer? _writePumpTimer;
  Timer? _keepAliveTimer;
  StreamSubscription? _notifySub;
  StreamSubscription? _connSub;

  final Map<int, List<Completer<DumlFrame>>> _waiters = {};
  final StreamController<DumlFrame> _frameStreamCtrl =
      StreamController.broadcast();

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String get address => _address;
  int get batteryPercent => _batteryPercent;
  bool get isCharging => _isCharging;
  Stream<DumlFrame> get frameStream => _frameStreamCtrl.stream;

  NanoBleDriver({this.onLog, this.onBatteryUpdate});

  void _log(String msg) {
    debugPrint('[NanoBleDriver] $msg');
    onLog?.call(msg);
  }

  Future<void> _ensureWinBleInit() async {
    if (_isBleInitialized) return;
    try {
      String serverPath;
      try {
        serverPath = await WinServer.path(fileName: 'nano_win_ble_server');
      } catch (_) {
        final tempPath =
            '${Platform.environment['LOCALAPPDATA']}\\Temp\\nano_win_ble_server.exe';
        if (File(tempPath).existsSync()) {
          serverPath = tempPath;
        } else {
          rethrow;
        }
      }
      await WinBle.initialize(serverPath: serverPath, enableLog: false);
      _isBleInitialized = true;
      _log('WinBle 初始化成功');
    } catch (e) {
      if (e.toString().contains('already initialized')) {
        _isBleInitialized = true;
      } else {
        _log('WinBle 初始化异常: $e');
        rethrow;
      }
    }
  }

  /// 扫描附近广播匹配的 DJI Osmo Nano 设备
  Future<String?> scanForNano(
      {Duration timeout = const Duration(seconds: 6)}) async {
    await _ensureWinBleInit();
    final completer = Completer<String?>();
    StreamSubscription? sub;

    sub = WinBle.scanStream.listen((BleDevice dev) {
      final name = dev.name.trim();
      final lowered = name.toLowerCase();
      if (lowered.contains('osmonano') ||
          lowered.contains('osmo nano') ||
          lowered.startsWith('osmo')) {
        _log('扫描发现目标 Nano 设备: $name (${dev.address}) RSSI: ${dev.rssi}');
        if (!completer.isCompleted) {
          completer.complete(dev.address);
        }
      }
    });

    try {
      WinBle.startScanning();
      final addr =
          await completer.future.timeout(timeout, onTimeout: () => null);
      return addr;
    } finally {
      WinBle.stopScanning();
      await sub.cancel();
    }
  }

  /// 连接目标 BLE 设备并初始化 GATT
  Future<bool> connect(String targetAddress,
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (_isConnecting) {
      _log('BLE 连接正在进行中，忽略重复连接请求');
      return false;
    }
    _isConnecting = true;
    try {
      await _ensureWinBleInit();

      // 若已有连接或残留会话，先确保断开并等待释放，防止 WinRT 报 "该对象已关闭" (0x80000013 / RO_E_CLOSED)
      if (_isConnected || _address.isNotEmpty) {
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 250));
      } else {
        try {
          await WinBle.disconnect(targetAddress);
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (_) {}
      }

      _address = targetAddress;
      _log('正在连接 Nano 蓝牙 GATT: $targetAddress...');
      try {
        await WinBle.connect(targetAddress);
      } catch (e) {
        _log('BLE 连接调用失败: $e');
        return false;
      }

      _isConnected = true;

      // 发现服务以确保连接建立
      final services = await WinBle.discoverServices(targetAddress);
      _log('发现 ${services.length} 个 GATT 服务');

      // 取消旧的断开监听并重新监听
      await _connSub?.cancel();
      _connSub = WinBle.connectionStreamOf(targetAddress).listen((connected) {
        if (!connected && _isConnected) {
          _log('收到蓝牙意外断开通知');
          _handleDisconnect();
        }
      });

      // 仅监听 FFF4 通知通道（FFF5 仅支持 WriteWithoutResponse，不可订阅）
      try {
        await WinBle.subscribeToCharacteristic(
          address: targetAddress,
          serviceId: bleServiceUuid,
          characteristicId: bleNotifyCharUuid,
        );

        final cleanTarget = targetAddress.replaceAll(':', '').toLowerCase();

        await _notifySub?.cancel();
        _notifySub = WinBle.characteristicValueStream.listen((event) {
          if (event is! Map) return;
          final devAddr = (event['address'] ?? '')
              .toString()
              .replaceAll(':', '')
              .toLowerCase();
          if (devAddr.isNotEmpty &&
              cleanTarget.isNotEmpty &&
              devAddr != cleanTarget) {
            return;
          }

          final rawVal = event['value'];
          if (rawVal is List) {
            try {
              final bytes = Uint8List.fromList(
                  rawVal.map((e) => (e as num).toInt()).toList());
              final frames = _assembler.append(bytes);
              for (final f in frames) {
                _dispatch(f);
              }
            } catch (e) {
              _log('解析 BLE 帧异常: $e');
            }
          }
        });
        _log('已订阅 FFF4 通知数据流');

        // 写入 01 00 进行 arm pairing
        try {
          await WinBle.write(
            address: targetAddress,
            service: bleServiceUuid,
            characteristic: bleNotifyCharUuid,
            data: Uint8List.fromList([0x01, 0x00]),
            writeWithResponse: true,
          );
          _log('已向 FFF4 写入 01 00 (Arm Pairing)');
        } catch (e) {
          _log('FFF4 arm pairing 写入提示: $e');
        }
      } catch (e) {
        _log('订阅 BLE 特征异常: $e');
      }

      // 启动 FFF5 限速写入泵 (120ms 间隔)
      _startWritePump();

      // 启动会话保活心跳（每 1.5 秒发送一次 sessionKeepalive），
      // 实测 Osmo Nano 固件有 4~5 秒看门狗，无保活帧会主动断开 BLE 链路；
      // BLE 纯心跳仅消耗微安级功耗，不会唤醒耗电的 5GHz SoftAP 或相机主控。
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (_isConnected) {
          send(sessionKeepalive());
        }
      });

      // 发送 sessionWake 促使相机主控唤醒并立即刷新推送 0x0D/0x02 电量状态
      send(sessionWake());

      // 等待首帧电量推送（通常在 200~1000ms 内到达），让连接成功后主界面能立刻展示真实电量百分比
      if (_batteryPercent < 0) {
        final sw = Stopwatch()..start();
        while (_batteryPercent < 0 &&
            sw.elapsedMilliseconds < 1500 &&
            _isConnected) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      return true;
    } finally {
      _isConnecting = false;
    }
  }

  void _startWritePump() {
    _writePumpTimer?.cancel();
    _writePumpTimer =
        Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (_writeQueue.isEmpty || !_isConnected || _address.isEmpty) return;
      final frame = _writeQueue.removeAt(0);
      try {
        final data = encodeDuml(frame);
        await WinBle.write(
          address: _address,
          service: bleServiceUuid,
          characteristic: bleWriteCharUuid,
          data: data,
          writeWithResponse: false,
        );
      } catch (e) {
        _log('FFF5 写入帧异常: $e');
      }
    });
  }

  void send(DumlFrame frame) {
    _writeQueue.add(frame);
  }

  void _dispatch(DumlFrame frame) {
    // 过滤掉高频常规遥测推送（00/99 参数流、02/80 系统状态流、0D/02 电量流），避免每秒几十帧日志刷屏
    final isHighFreqTelemetry = (frame.cmdSet == 0x00 && frame.cmdId == 0x99) ||
        (frame.cmdSet == 0x02 && frame.cmdId == 0x80) ||
        (frame.cmdSet == 0x0D && frame.cmdId == 0x02);
    if (!isHighFreqTelemetry) {
      _log(
          '收到 DUML 帧: 0x${frame.cmdSet.toRadixString(16).padLeft(2, '0')}/0x${frame.cmdId.toRadixString(16).padLeft(2, '0')} (flags: 0x${frame.flags.toRadixString(16)}, len: ${frame.payload.length})');
    }
    _frameStreamCtrl.add(frame);

    // 自动同意配对审批请求 (0x07/0x46, flags 0x40)
    if (frame.cmdSet == 0x07 &&
        frame.cmdId == 0x46 &&
        frame.flags == flagRequest) {
      _log('收到相机配对审批请求，自动回复确认');
      send(pairApprovalAck(frame.seq));
    }

    // 解析 0x0D/0x02 遥测帧中的电量与充电状态
    if (frame.cmdSet == 0x0D && frame.cmdId == 0x02) {
      final p = frame.payload;
      if (p.length >= 21) {
        final battery = p[20];
        final charging = p.length > 32 ? (p[32] != 0) : false;
        if (battery >= 0 && battery <= 100) {
          final changed = battery != _batteryPercent || charging != _isCharging;
          _batteryPercent = battery;
          _isCharging = charging;
          if (changed) {
            _log('更新 Nano 电量: $_batteryPercent% (充电状态: $_isCharging)');
            onBatteryUpdate?.call(_batteryPercent, _isCharging);
          }
        }
      }
    }

    // 满足等待者
    final list = _waiters[frame.key];
    if (list != null && list.isNotEmpty) {
      final completer = list.removeAt(0);
      if (!completer.isCompleted) {
        completer.complete(frame);
      }
    }
  }

  Future<DumlFrame?> waitForFrame(int key,
      {Duration timeout = const Duration(seconds: 4)}) {
    final completer = Completer<DumlFrame>();
    _waiters.putIfAbsent(key, () => []).add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters[key]?.remove(completer);
      return throw TimeoutException(
          '等待 BLE 帧 (0x${key.toRadixString(16).toUpperCase()}) 超时');
    });
  }

  /// 自动协商 PIN 配对（相机屏幕点允许后解锁 Wi-Fi 凭据）
  Future<bool> pair({Duration timeout = const Duration(seconds: 15)}) async {
    send(sessionWake());
    send(setPairingPin());
    final deadline = DateTime.now().add(timeout);
    DateTime lastPin = DateTime.now();

    while (DateTime.now().isBefore(deadline)) {
      try {
        final frame =
            await waitForFrame(0x0745, timeout: const Duration(seconds: 2));
        if (frame != null &&
            frame.payload.length >= 2 &&
            frame.payload[0] == 0x00) {
          final code = frame.payload[1];
          if (code == 0x01) {
            _log('配对已解锁: 已授权 (00 01)');
            return true;
          } else if (code == 0x02) {
            _log('配对等待中: 请在相机屏幕上点击允许');
          } else if (code == 0x06) {
            _log('配对暂缓，重发 SetPairingPIN');
            send(setPairingPin());
            lastPin = DateTime.now();
          }
        }
      } catch (_) {}

      if (DateTime.now().difference(lastPin).inSeconds >= 4) {
        send(setPairingPin());
        lastPin = DateTime.now();
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// 从 BLE 自动读取 Wi-Fi 凭证 (SSID 与 Password)
  Future<(String, String)> readWifiCredentials(
      {Duration timeout = const Duration(seconds: 10)}) async {
    // 1. 发送唤醒与 SoftAP 拉起帧
    send(sessionWake());
    send(session5310());
    await Future.delayed(const Duration(milliseconds: 600));

    // 2. 发送 PIN 配对鉴权（相机需要 SetPairingPIN 来解锁 Wi-Fi 凭据访问）
    _log('正在向相机申请配对认证 (SetPairingPIN)...');
    final isPaired = await pair(timeout: const Duration(seconds: 6));
    _log('配对认证状态: ${isPaired ? "已授权 (00 01)" : "未完成或需屏幕确认"}');

    String ssid = '';
    String password = '';

    Future<void> queryCredentials() async {
      send(getWifiSsid());
      try {
        final ssidFrame =
            await waitForFrame(0x0707, timeout: const Duration(seconds: 3));
        if (ssidFrame != null) {
          ssid = unpackStatusString(ssidFrame.payload);
        }
      } catch (e) {
        _log('读取 SSID 帧超时或异常: $e');
      }

      send(getWifiPassword());
      try {
        final pwdFrame =
            await waitForFrame(0x070E, timeout: const Duration(seconds: 3));
        if (pwdFrame != null) {
          password = unpackStatusString(pwdFrame.payload);
        }
      } catch (e) {
        _log('读取 Password 帧超时或异常: $e');
      }
    }

    await queryCredentials();

    // 3. 若仍未读取到且此前未授权，再次重试配对并查询
    if (ssid.isEmpty || password.isEmpty) {
      if (!isPaired) {
        _log('尚未解锁凭证，重新发起配对并等待相机确认...');
        final ok = await pair(timeout: const Duration(seconds: 8));
        if (ok) {
          send(session5310());
          await Future.delayed(const Duration(milliseconds: 500));
          await queryCredentials();
        }
      }
    }

    // 4. 本地环境凭据回退检查（如已有 hw_creds.txt 容灾）
    if (ssid.isEmpty || password.isEmpty) {
      final fallback = _readOfflineCredsFile();
      if (fallback != null) {
        ssid = fallback.$1;
        password = fallback.$2;
        _log('已从本地缓存文件读取到凭证回退: SSID="$ssid"');
      }
    }

    _log(
        '自动获取 Wi-Fi 凭证完成: SSID="$ssid", Password="${password.isNotEmpty ? '******' : ''}"');
    return (ssid, password);
  }

  (String, String)? _readOfflineCredsFile() {
    final candidatePaths = [
      '${Directory.current.path}/NanoTest/hw_creds.txt',
      'c:/Code/SideAssistant/NanoTest/hw_creds.txt',
      '${Directory.current.path}/hw_creds.txt',
    ];
    for (final p in candidatePaths) {
      final f = File(p);
      if (f.existsSync()) {
        try {
          final lines = f
              .readAsLinesSync()
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          if (lines.length >= 2) {
            return (lines[0], lines[1]);
          }
        } catch (_) {}
      }
    }
    return null;
  }

  void _handleDisconnect() {
    _isConnected = false;
    _batteryPercent = -1;
    _isCharging = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _writePumpTimer?.cancel();
    _writePumpTimer = null;
    if (_address.isNotEmpty) {
      try {
        WinBle.disconnect(_address);
      } catch (_) {}
    }
    onBatteryUpdate?.call(-1, false);
  }

  Future<void> disconnect() async {
    _handleDisconnect();
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;

    _writeQueue.clear();
    for (final list in _waiters.values) {
      for (final c in list) {
        if (!c.isCompleted) {
          c.completeError(Exception('BLE 连接已断开'));
        }
      }
    }
    _waiters.clear();
    _log('Nano 蓝牙已完全断开并释放');
  }
}
