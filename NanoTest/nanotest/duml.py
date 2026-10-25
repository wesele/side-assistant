"""DUML wire framing for DJI Osmo cameras.

Ported from OpenPocketCine / OpenCine (`DumlFrame.swift`), Apache-2.0.
Plaintext; no crypto.

Frame layout (total = 13 + len(payload)):
  55 | len_lo | (ver<<2)|len_hi | crc8(b[0:3]) |
  sender | receiver | seq:u16le | flags | cmdSet | cmdId | payload | crc16:u16le
"""

from __future__ import annotations

from dataclasses import dataclass, field

SENDER_APP = 0x02
RX_CAMERA = 0x01
RX_WIFI = 0x07
RX_SESSION = 0xF0
RX_1C = 0x1C

FLAG_REQUEST = 0x40
FLAG_RESPONSE = 0xC0
FLAG_NOTIFY = 0x00
FLAG_ACK_80 = 0x80


def crc8(data: bytes) -> int:
    """Reflected CRC-8, init 0x77, poly 0x8C, over the 3 header bytes."""
    c = 0x77
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = ((c >> 1) ^ 0x8C) if (c & 1) else (c >> 1)
    return c & 0xFF


def crc16(data: bytes) -> int:
    """Reflected CRC-16, init 0x3692, poly 0x8408, over the frame minus the CRC."""
    c = 0x3692
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = ((c >> 1) ^ 0x8408) if (c & 1) else (c >> 1)
    return c & 0xFFFF


@dataclass
class Frame:
    sender: int
    receiver: int
    seq: int
    flags: int
    cmd_set: int
    cmd_id: int
    payload: bytes = b""

    @property
    def key(self) -> int:
        return (self.cmd_set << 8) | self.cmd_id

    def hex(self, limit: int = 24) -> str:
        if not self.payload:
            return "-"
        head = " ".join(f"{b:02X}" for b in self.payload[:limit])
        return head + ("..." if len(self.payload) > limit else "")

    def __str__(self) -> str:
        return (
            f"{self.cmd_set:02X}/{self.cmd_id:02X} "
            f"sender={self.sender:02X} rcv={self.receiver:02X} seq={self.seq} "
            f"flags={self.flags:02X} len={len(self.payload)} [{self.hex()}]"
        )


def encode(f: Frame) -> bytes:
    total = 13 + len(f.payload)
    b = bytearray()
    b.append(0x55)
    b.append(total & 0xFF)
    b.append((1 << 2) | ((total >> 8) & 0x03))
    b.append(crc8(bytes(b[0:3])))
    b.append(f.sender & 0xFF)
    b.append(f.receiver & 0xFF)
    b.append(f.seq & 0xFF)
    b.append((f.seq >> 8) & 0xFF)
    b.append(f.flags & 0xFF)
    b.append(f.cmd_set & 0xFF)
    b.append(f.cmd_id & 0xFF)
    b += f.payload
    c = crc16(bytes(b))
    b.append(c & 0xFF)
    b.append((c >> 8) & 0xFF)
    return bytes(b)


def scan_frames(raw: bytes) -> list[Frame]:
    """Every CRC-valid DUML frame in `raw`, byte-at-a-time.

    Both CRCs are checked, which is what makes the byte-at-a-time scan safe.
    """
    out: list[Frame] = []
    i = 0
    n = len(raw)
    while i + 13 <= n:
        if raw[i] != 0x55:
            i += 1
            continue
        total = raw[i + 1] | ((raw[i + 2] & 0x03) << 8)
        if (raw[i + 2] >> 2) != 1 or total < 13 or i + total > n:
            i += 1
            continue
        end = i + total
        if crc8(raw[i : i + 3]) != raw[i + 3]:
            i += 1
            continue
        got = raw[end - 2] | (raw[end - 1] << 8)
        if crc16(raw[i : end - 2]) != got:
            i += 1
            continue
        out.append(
            Frame(
                sender=raw[i + 4],
                receiver=raw[i + 5],
                seq=raw[i + 6] | (raw[i + 7] << 8),
                flags=raw[i + 8],
                cmd_set=raw[i + 9],
                cmd_id=raw[i + 10],
                payload=bytes(raw[i + 11 : end - 2]),
            )
        )
        i += 1
    return out


def pack_string(s: str) -> bytes:
    """`[len:u8][utf8]` - how the WiFi subsystem packs strings."""
    raw = s.encode("utf-8")
    return bytes([len(raw)]) + raw


def unpack_status_string(p: bytes) -> str:
    """WiFi-subsystem reply `[status][len][utf8...]`."""
    if len(p) < 2:
        return ""
    end = min(2 + p[1], len(p))
    return p[2:end].decode("utf-8", "replace")


def u16(p: bytes, off: int) -> int:
    return p[off] | (p[off + 1] << 8)


def u32(p: bytes, off: int) -> int:
    return p[off] | (p[off + 1] << 8) | (p[off + 2] << 16) | (p[off + 3] << 24)


def le16(v: int) -> bytes:
    return bytes([v & 0xFF, (v >> 8) & 0xFF])


def le32(v: int) -> bytes:
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])
