import 'dart:typed_data';
import 'duml_packet.dart';

const String defaultIdentifier = '284ae5b8d76b3375a04a6417ad71bea3';
const String pairingToken = 'osmo';

int rx(int type, int ident) => ((ident << 5) | type) & 0xFF;

DumlFrame cameraCmd(int cmdId, Uint8List payload, [int seq = 0]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxCamera,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x02,
    cmdId: cmdId,
    payload: payload,
  );
}

// ---- BLE session sequence ----

DumlFrame sessionWake([int seq = 0x802B]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxSession,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x00,
    cmdId: 0x2B,
    payload: Uint8List.fromList([0x04, 0x00]),
  );
}

DumlFrame sessionKeepalive([int seq = 0x802B]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxSession,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x00,
    cmdId: 0x2B,
    payload: Uint8List.fromList([0x01, 0x01]),
  );
}

DumlFrame setPairingPin([int seq = 0x8092, String pin = pairingToken]) {
  final idPart = packString(defaultIdentifier);
  final pinPart = packString(pin);
  final b = BytesBuilder(copy: false);
  b.add(idPart);
  b.add(pinPart);
  return DumlFrame(
    sender: senderApp,
    receiver: rxWifi,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x07,
    cmdId: 0x45,
    payload: b.toBytes(),
  );
}

DumlFrame pairApprovalAck(int seq) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxWifi,
    seq: seq,
    flags: flagResponse,
    cmdSet: 0x07,
    cmdId: 0x46,
    payload: Uint8List.fromList([0x00]),
  );
}

DumlFrame session5310([int seq = 0x8053]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rx1C,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x53,
    cmdId: 0x10,
    payload: Uint8List.fromList([0x00, 0x00, 0x00, 0x00]),
  );
}

DumlFrame getWifiSsid([int seq = 0x8007]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxWifi,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x07,
    cmdId: 0x07,
    payload: Uint8List(0),
  );
}

DumlFrame getWifiPassword([int seq = 0x800E]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxWifi,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x07,
    cmdId: 0x0E,
    payload: Uint8List(0),
  );
}

// ---- Datalink registration ----

DumlFrame appDeviceInfo(int seq) {
  final b = Uint8List(62);
  b[1] = 0x41; // 'A'
  b[2] = 0x50; // 'P'
  b[3] = 0x50; // 'P'
  b[41] = 0x02;
  b[50] = 0x02;
  b[51] = 0x08;
  return DumlFrame(
    sender: senderApp,
    receiver: rx(0x08, 2),
    seq: seq,
    flags: 0x80,
    cmdSet: 0x00,
    cmdId: 0x81,
    payload: b,
  );
}

final Uint8List appPresencePayload = Uint8List.fromList([
  0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
]);

DumlFrame appPresenceFrame(int seq) {
  return DumlFrame(
    sender: senderApp,
    receiver: rx(0x08, 1),
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x00,
    cmdId: 0x88,
    payload: appPresencePayload,
  );
}

// ---- Camera control ----

DumlFrame shootPhoto([int seq = 0]) {
  return cameraCmd(0x01, Uint8List.fromList([0x01]), seq);
}

DumlFrame setShootingMode(int modeByte, [int seq = 0]) {
  return cameraCmd(0xE1, Uint8List.fromList([modeByte & 0xFF]), seq);
}

// ---- Media list ----

final Uint8List listTemplate = Uint8List.fromList([
  0x4A, 0x00, 0x2A, 0x10,
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00,
  0x2D, 0x00, 0x0D, 0x01, 0x00,
  0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
  0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00,
]);

DumlFrame mediaList(int counter, int cursor, [int seq = 0]) {
  final p = Uint8List.fromList(listTemplate);
  p[4] = counter & 0xFF;
  final curBytes = le32(cursor);
  p.setRange(10, 14, curBytes);
  return DumlFrame(
    sender: senderApp,
    receiver: rxCamera,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x00,
    cmdId: 0x26,
    payload: p,
  );
}

final Uint8List listTrigger = Uint8List.fromList([
  0x4A, 0x04, 0x0E, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
]);

DumlFrame mediaListTrigger([int seq = 0]) {
  return DumlFrame(
    sender: senderApp,
    receiver: rxCamera,
    seq: seq,
    flags: flagRequest,
    cmdSet: 0x00,
    cmdId: 0x26,
    payload: listTrigger,
  );
}
