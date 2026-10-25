import 'dart:async';
import 'dart:io';
import 'dart:math';
import '../../../core/platform/foundation_bridge.dart';
import 'duml_packet.dart';
import 'nano_commands.dart';

const int pktHandshake = 0x00;
const int pktTelemetry = 0x01;
const int pktVideo = 0x02;
const int pktAcked = 0x03;
const int pktAck = 0x04;
const int pktCommand = 0x05;

Uint8List transportHeader(int pktType, int payloadLen, int sessionId, int seq) {
  final total = 8 + payloadLen;
  final w0 = 0x8000 | (total & 0x3FFF);
  final b = Uint8List(8);
  b[0] = w0 & 0xFF;
  b[1] = (w0 >> 8) & 0xFF;
  b[2] = sessionId & 0xFF;
  b[3] = (sessionId >> 8) & 0xFF;
  b[4] = seq & 0xFF;
  b[5] = (seq >> 8) & 0xFF;
  b[6] = pktType & 0xFF;
  int x = 0;
  for (int i = 0; i < 7; i++) {
    x ^= b[i];
  }
  b[7] = x & 0xFF;
  return b;
}

Uint8List routingHeader(int seq, int cmdCounter) {
  final ack = (seq - 8) & 0xFFFF;
  final b = Uint8List(12);
  b[0] = ack & 0xFF;
  b[1] = (ack >> 8) & 0xFF;
  b[2] = seq & 0xFF;
  b[3] = (seq >> 8) & 0xFF;
  b[8] = cmdCounter & 0xFF;
  b[9] = 0x01;
  return b;
}

final Uint8List _handshakePayloadTemplate = Uint8List.fromList([
  0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
  0x00, 0x64, 0x00, 0x00, 0x01, 0x90,
  0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00,
  0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
  0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02,
]);

Uint8List handshakeDatagram(int sessionId, int seq, int baseSeq) {
  final p = Uint8List.fromList(_handshakePayloadTemplate);
  p[0] = baseSeq & 0xFF;
  p[1] = (baseSeq >> 8) & 0xFF;
  final hdr = transportHeader(pktHandshake, p.length, sessionId, seq);
  final full = BytesBuilder(copy: false);
  full.add(hdr);
  full.add(p);
  return full.toBytes();
}

Uint8List ackPayload(int peerCursor, int ackedDataCursor, int extraCursor) {
  Uint8List grp(int v) {
    return Uint8List.fromList([
      v & 0xFF, (v >> 8) & 0xFF,
      v & 0xFF, (v >> 8) & 0xFF,
      0, 0, 0, 0,
    ]);
  }
  final b = BytesBuilder(copy: false);
  b.add(grp(peerCursor));
  b.add(grp(ackedDataCursor));
  b.add(grp(extraCursor));
  b.add(Uint8List(2));
  return b.toBytes();
}

Uint8List ackDatagram(int sessionId, int peer, int acked, int extra) {
  final p = ackPayload(peer, acked, extra);
  final hdr = transportHeader(pktAck, p.length, sessionId, 0);
  final full = BytesBuilder(copy: false);
  full.add(hdr);
  full.add(p);
  return full.toBytes();
}

class NanoDatalink {
  final String host;
  final int port;
  final void Function(String message)? onLog;

  Socket? _tcpSocket;
  RawDatagramSocket? _udpSocket;
  StreamSubscription? _udpSub;
  Timer? _ackPumpTimer;
  Timer? _regTimer;

  Completer<void>? _handshakeAckCompleter;
  int? _initialWindowSeq;

  int _sessionId = 0;
  int _baseSeq = 0;
  int _udpSeq = 0;
  int _dumlSeq = 0xA000;
  int _cmdCounter = 0;

  int _lastVideoSeq = 0;
  int _ackedData = 0;
  int _extra = 0;
  bool _sawAcked = false;
  bool _sawExtra = false;

  final Map<int, List<Completer<DumlFrame>>> _waiters = {};
  final StreamController<DumlFrame> _frameStreamCtrl = StreamController.broadcast();

  Stream<DumlFrame> get frameStream => _frameStreamCtrl.stream;
  bool get isConnected => _udpSocket != null;

  NanoDatalink({
    this.host = '192.168.2.1',
    this.port = 9004,
    this.onLog,
  });

  void _log(String msg) {
    debugPrint('[NanoDatalink] $msg');
    onLog?.call(msg);
  }

  /// 开启 TCP 7001 poke 与 UDP 9004 握手
  Future<bool> connect({required String localIp, Duration timeout = const Duration(seconds: 15)}) async {
    final rng = Random();
    _sessionId = rng.nextInt(0xE000) + 0x1000;
    _baseSeq = (rng.nextInt(0xE000) + 0x1000) & 0xFFF8;
    _udpSeq = 0;
    _cmdCounter = 0;

    // 1. TCP 7001 Poke (必须保持打开，否则相机 RST)
    try {
      _log('正在连接 TCP 7001 poke (本地IP: $localIp)...');
      _tcpSocket = await Socket.connect(
        host,
        7001,
        sourceAddress: InternetAddress(localIp),
        timeout: const Duration(seconds: 4),
      );
      _tcpSocket!.add(encodeDuml(setPairingPin()));
      await _tcpSocket!.flush();
      _tcpSocket!.listen(
        (data) {},
        onError: (e) => _log('TCP poke 数据流错误: $e'),
        onDone: () => _log('TCP poke 连接关闭'),
      );
      _log('TCP 7001 poke 握手帧已发送');
    } catch (e) {
      _log('TCP 7001 poke 异常: $e (继续尝试 UDP 链路)');
    }

    _handshakeAckCompleter = Completer<void>();
    _initialWindowSeq = null;

    // 2. 绑定本地 UDP 端口（单一持久监听，彻底避免 Bad state 异常）
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress(localIp), 0);
      _udpSocket!.readEventsEnabled = true;
      _udpSub = _udpSocket!.listen(_handleUdpEvent);
      _log('UDP 已绑定 $localIp:${_udpSocket!.port} -> $host:$port');
    } catch (e) {
      _log('UDP 绑定失败: $e');
      await close();
      return false;
    }

    // 3. UDP 握手循环
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline) && !_handshakeAckCompleter!.isCompleted) {
      final packet = handshakeDatagram(_sessionId, _udpSeq, _baseSeq);
      _udpSocket!.send(packet, InternetAddress(host), port);
      _udpSeq = (_udpSeq + 8) & 0xFFFF;

      try {
        await _handshakeAckCompleter!.future.timeout(const Duration(milliseconds: 350));
        break;
      } catch (_) {}
    }

    if (!_handshakeAckCompleter!.isCompleted) {
      _log('UDP 9004 握手超时无回执');
      await close();
      return false;
    }

    _log('UDP 9004 握手成功 (Session ID: 0x${_sessionId.toRadixString(16).toUpperCase()})');

    // 等待首帧 command window seq
    final winDeadline = DateTime.now().add(const Duration(milliseconds: 1500));
    while (DateTime.now().isBefore(winDeadline) && _initialWindowSeq == null) {
      await Future.delayed(const Duration(milliseconds: 25));
    }

    if (_initialWindowSeq != null) {
      _udpSeq = _initialWindowSeq!;
      _log('初始命令序列窗口: 0x${_udpSeq.toRadixString(16).toUpperCase()}');
    } else {
      _udpSeq = _baseSeq;
      _log('未收到初始窗口帧，降级使用 baseSeq');
    }

    // 4. 发送初始设备信息与开启 40Hz ACK 泵与 1Hz 保活泵
    _sendAck();
    sendCommand(appDeviceInfo(_dumlSeq));

    _ackPumpTimer = Timer.periodic(const Duration(milliseconds: 25), (_) => _sendAck());
    _regTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      sendCommand(appDeviceInfo(_dumlSeq));
      sendCommand(appPresenceFrame(_dumlSeq));
    });

    return true;
  }

  static bool _forward(int candidate, int current) {
    final delta = (candidate - current) & 0xFFFF;
    return delta != 0 && delta < 0x8000;
  }

  void _handleUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udpSocket == null) return;
    while (true) {
      final dg = _udpSocket?.receive();
      if (dg == null) break;
      final data = dg.data;
      if (data.length < 8) continue;

      final pktType = data[6];

      if (pktType == pktVideo && data.length >= 6) {
        _lastVideoSeq = data[4] | (data[5] << 8);
        continue;
      }

      // 处理 UDP 握手包回执
      if (pktType == pktHandshake) {
        if (_handshakeAckCompleter != null && !_handshakeAckCompleter!.isCompleted) {
          _handshakeAckCompleter!.complete();
        }
        continue;
      }

      // 更新 ACK 窗口与提取初始命令窗口
      if (pktType == pktTelemetry && data.length >= 34) {
        _initialWindowSeq ??= ((data[8] | (data[9] << 8)) + 8) & 0xFFFF;
        final acked = data[18] | (data[19] << 8);
        final extra = data[26] | (data[27] << 8);
        if (!_sawAcked || acked == _ackedData || _forward(acked, _ackedData)) {
          _ackedData = acked;
          _sawAcked = true;
        }
        _extra = extra;
        _sawExtra = true;
      } else if (pktType == pktAcked && data.length >= 8) {
        final seq = data[4] | (data[5] << 8);
        if (!_sawAcked || seq == _ackedData || _forward(seq, _ackedData)) {
          _ackedData = seq;
          _sawAcked = true;
        }
      }

      // 扫描提取 DUML 帧
      final frames = scanDumlFrames(data);
      for (final frame in frames) {
        if (frame.cmdSet == 0x00 && (frame.cmdId == 0x26 || frame.cmdId == 0x27)) {
          _log('[UDP DUML] 0x${frame.cmdSet.toRadixString(16)}/0x${frame.cmdId.toRadixString(16)} flags: 0x${frame.flags.toRadixString(16)}, len: ${frame.payload.length}, hex: ${frame.hexPayload}');
        }
        _frameStreamCtrl.add(frame);
        final list = _waiters[frame.key];
        if (list != null && list.isNotEmpty) {
          final completer = list.removeAt(0);
          if (!completer.isCompleted) {
            completer.complete(frame);
          }
        }
      }
    }
  }

  void _sendAck() {
    if (_udpSocket == null) return;
    _cachedTargetAddress ??= InternetAddress(host);
    final acked = _sawAcked ? _ackedData : _baseSeq;
    final extra = _sawExtra ? _extra : _baseSeq;
    final packet = ackDatagram(_sessionId, _lastVideoSeq, acked, extra);
    _udpSocket!.send(packet, _cachedTargetAddress!, port);
  }

  InternetAddress? _cachedTargetAddress;

  int sendCommand(DumlFrame frame) {
    if (_udpSocket == null) return 0;
    _cachedTargetAddress ??= InternetAddress(host);
    frame.seq = _dumlSeq;
    final seq = frame.seq;
    _dumlSeq = (_dumlSeq + 1) & 0xFFFF;

    final routing = routingHeader(_udpSeq, _cmdCounter);
    _cmdCounter = (_cmdCounter + 1) & 0xFF;

    final duml = encodeDuml(frame);
    final payloadBuilder = BytesBuilder(copy: false);
    payloadBuilder.add(routing);
    payloadBuilder.add(duml);
    final payload = payloadBuilder.toBytes();

    final hdr = transportHeader(pktCommand, payload.length, _sessionId, _udpSeq);
    final packetBuilder = BytesBuilder(copy: false);
    packetBuilder.add(hdr);
    packetBuilder.add(payload);
    final packet = packetBuilder.toBytes();

    _log('--> [UDP SEND] udpSeq=0x${_udpSeq.toRadixString(16).toUpperCase()} cmdCounter=$_cmdCounter DUML: 0x${frame.cmdSet.toRadixString(16)}/0x${frame.cmdId.toRadixString(16)} len=${payload.length}');
    final sent = _udpSocket!.send(packet, _cachedTargetAddress!, port);
    if (sent <= 0) {
      _log('[!] UDP send returned $sent');
    }
    _udpSeq = (_udpSeq + 8) & 0xFFFF;
    return seq;
  }

  Future<DumlFrame?> waitForFrame(int key, {Duration timeout = const Duration(seconds: 4)}) {
    final completer = Completer<DumlFrame>();
    _waiters.putIfAbsent(key, () => []).add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters[key]?.remove(completer);
      return throw TimeoutException('等待 DUML 帧 (0x${key.toRadixString(16).toUpperCase()}) 超时');
    });
  }

  Future<void> close() async {
    _ackPumpTimer?.cancel();
    _ackPumpTimer = null;
    _regTimer?.cancel();
    _regTimer = null;

    await _udpSub?.cancel();
    _udpSub = null;

    if (_udpSocket != null) {
      try {
        _udpSocket!.close();
      } catch (_) {}
      _udpSocket = null;
    }

    if (_tcpSocket != null) {
      try {
        await _tcpSocket!.close();
      } catch (_) {}
      _tcpSocket = null;
    }

    for (final list in _waiters.values) {
      for (final c in list) {
        if (!c.isCompleted) {
          c.completeError(Exception('数据链路已关闭'));
        }
      }
    }
    _waiters.clear();
    _log('Datalink 数据链路已完全断开释放');
  }
}
