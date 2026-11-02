import 'dart:convert';
import 'dart:typed_data';

const int senderApp = 0x02;
const int rxCamera = 0x01;
const int rxWifi = 0x07;
const int rxSession = 0xF0;
const int rx1C = 0x1C;

const int flagRequest = 0x40;
const int flagResponse = 0xC0;
const int flagNotify = 0x00;

/// Reflected CRC-8, init 0x77, poly 0x8C, over the 3 header bytes.
int crc8(List<int> data) {
  int c = 0x77;
  for (final byte in data) {
    c ^= (byte & 0xFF);
    for (int j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? ((c >> 1) ^ 0x8C) : (c >> 1);
    }
  }
  return c & 0xFF;
}

/// Reflected CRC-16, init 0x3692, poly 0x8408, over the frame minus the CRC.
int crc16(List<int> data) {
  int c = 0x3692;
  for (final byte in data) {
    c ^= (byte & 0xFF);
    for (int j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? ((c >> 1) ^ 0x8408) : (c >> 1);
    }
  }
  return c & 0xFFFF;
}

class DumlFrame {
  final int sender;
  final int receiver;
  int seq;
  final int flags;
  final int cmdSet;
  final int cmdId;
  final Uint8List payload;

  DumlFrame({
    required this.sender,
    required this.receiver,
    this.seq = 0,
    required this.flags,
    required this.cmdSet,
    required this.cmdId,
    Uint8List? payload,
  }) : payload = payload ?? Uint8List(0);

  int get key => (cmdSet << 8) | cmdId;

  String get hexPayload {
    if (payload.isEmpty) return '-';
    final limit = payload.length > 24 ? 24 : payload.length;
    final head = payload
        .sublist(0, limit)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    return payload.length > 24 ? '$head...' : head;
  }

  @override
  String toString() {
    final cs = cmdSet.toRadixString(16).padLeft(2, '0').toUpperCase();
    final ci = cmdId.toRadixString(16).padLeft(2, '0').toUpperCase();
    final s = sender.toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = receiver.toRadixString(16).padLeft(2, '0').toUpperCase();
    final f = flags.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '$cs/$ci sender=$s rcv=$r seq=$seq flags=$f len=${payload.length} [$hexPayload]';
  }
}

Uint8List encodeDuml(DumlFrame f) {
  final total = 13 + f.payload.length;
  final b = BytesBuilder(copy: false);
  final lenLo = total & 0xFF;
  final verLenHi = (1 << 2) | ((total >> 8) & 0x03);
  b.addByte(0x55);
  b.addByte(lenLo);
  b.addByte(verLenHi);
  b.addByte(crc8([0x55, lenLo, verLenHi]));

  b.addByte(f.sender & 0xFF);
  b.addByte(f.receiver & 0xFF);
  b.addByte(f.seq & 0xFF);
  b.addByte((f.seq >> 8) & 0xFF);
  b.addByte(f.flags & 0xFF);
  b.addByte(f.cmdSet & 0xFF);
  b.addByte(f.cmdId & 0xFF);
  if (f.payload.isNotEmpty) {
    b.add(f.payload);
  }

  final frameWithoutCrc = b.toBytes();
  final c = crc16(frameWithoutCrc);
  final full = BytesBuilder(copy: false);
  full.add(frameWithoutCrc);
  full.addByte(c & 0xFF);
  full.addByte((c >> 8) & 0xFF);
  return full.toBytes();
}

List<DumlFrame> scanDumlFrames(Uint8List raw) {
  final List<DumlFrame> out = [];
  int i = 0;
  final n = raw.length;
  while (i + 13 <= n) {
    if (raw[i] != 0x55) {
      i++;
      continue;
    }
    final total = raw[i + 1] | ((raw[i + 2] & 0x03) << 8);
    if ((raw[i + 2] >> 2) != 1 || total < 13 || i + total > n) {
      i++;
      continue;
    }
    final end = i + total;
    if (crc8(Uint8List.sublistView(raw, i, i + 3)) != raw[i + 3]) {
      i++;
      continue;
    }
    final got = raw[end - 2] | (raw[end - 1] << 8);
    if (crc16(Uint8List.sublistView(raw, i, end - 2)) != got) {
      i++;
      continue;
    }
    out.add(
      DumlFrame(
        sender: raw[i + 4],
        receiver: raw[i + 5],
        seq: raw[i + 6] | (raw[i + 7] << 8),
        flags: raw[i + 8],
        cmdSet: raw[i + 9],
        cmdId: raw[i + 10],
        payload: Uint8List.fromList(raw.sublist(i + 11, end - 2)),
      ),
    );
    i += total;
  }
  return out;
}

Uint8List packString(String s) {
  final raw = utf8.encode(s);
  final b = BytesBuilder(copy: false);
  b.addByte(raw.length & 0xFF);
  b.add(raw);
  return b.toBytes();
}

String unpackStatusString(Uint8List p) {
  if (p.length < 2) return '';
  final slen = p[1];
  final end = (2 + slen) > p.length ? p.length : 2 + slen;
  return utf8.decode(p.sublist(2, end), allowMalformed: true);
}

Uint8List le32(int v) {
  final b = Uint8List(4);
  b[0] = v & 0xFF;
  b[1] = (v >> 8) & 0xFF;
  b[2] = (v >> 16) & 0xFF;
  b[3] = (v >> 24) & 0xFF;
  return b;
}
