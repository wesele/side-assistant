"""DUML-over-UDP datalink framing: 8-byte transport header, 12-byte routing
header, handshake and window-ACK payloads.

Ported from OpenPocketCine / OpenCine (`DumlTransport.swift`), Apache-2.0.
"""

from __future__ import annotations

import struct

PKT_HANDSHAKE = 0x00
PKT_TELEMETRY = 0x01
PKT_VIDEO = 0x02
PKT_ACKED = 0x03
PKT_ACK = 0x04
PKT_COMMAND = 0x05


def transport_header(pkt_type: int, payload_len: int, session_id: int, seq: int) -> bytes:
    """`[u16le 0x8000|total][u16le session][u16le seq][u8 pktType][u8 xor]`."""
    total = 8 + payload_len
    w0 = 0x8000 | (total & 0x3FFF)
    b = bytearray(
        [
            w0 & 0xFF,
            (w0 >> 8) & 0xFF,
            session_id & 0xFF,
            (session_id >> 8) & 0xFF,
            seq & 0xFF,
            (seq >> 8) & 0xFF,
            pkt_type & 0xFF,
        ]
    )
    x = 0
    for v in b:
        x ^= v
    b.append(x)
    return bytes(b)


def routing_header(seq: int, cmd_counter: int, drone: bool = False) -> bytes:
    """`[u16le ack=seq-8][u16le seq][00 00 00 00][counter][01][drone?60:00][00]`."""
    ack = (seq - 8) & 0xFFFF
    return struct.pack(
        "<HHBBBBBBBB",
        ack,
        seq,
        0,
        0,
        0,
        0,
        cmd_counter & 0xFF,
        0x01,
        0x60 if drone else 0x00,
        0x00,
    )


def handshake_payload(base_seq: int) -> bytes:
    """40-byte handshake payload; first two bytes are an 8-aligned base seq."""
    p = bytearray(
        [
            0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
            0x00, 0x64, 0x00, 0x00, 0x01, 0x90,
            0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00,
            0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
            0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02,
        ]
    )
    p[0] = base_seq & 0xFF
    p[1] = (base_seq >> 8) & 0xFF
    return bytes(p)


def handshake_datagram(session_id: int, seq: int, base_seq: int) -> bytes:
    payload = handshake_payload(base_seq)
    return transport_header(PKT_HANDSHAKE, len(payload), session_id, seq) + payload


def ack_payload(peer_cursor: int, acked_data_cursor: int, extra_cursor: int) -> bytes:
    """26-byte pktType-0x04 payload: three 8-byte groups + 2 zero bytes."""

    def grp(v: int) -> bytes:
        return bytes([v & 0xFF, (v >> 8) & 0xFF, v & 0xFF, (v >> 8) & 0xFF, 0, 0, 0, 0])

    return grp(peer_cursor) + grp(acked_data_cursor) + grp(extra_cursor) + b"\x00\x00"


def ack_datagram(session_id: int, peer: int, acked: int, extra: int) -> bytes:
    payload = ack_payload(peer, acked, extra)
    return transport_header(PKT_ACK, len(payload), session_id, 0) + payload


def header_fields(datagram: bytes):
    """Return (total, session, seq, pkt_type) or None."""
    if len(datagram) < 8:
        return None
    total = struct.unpack_from("<H", datagram, 0)[0] & 0x3FFF
    session = struct.unpack_from("<H", datagram, 2)[0]
    seq = struct.unpack_from("<H", datagram, 4)[0]
    return total, session, seq, datagram[6]


def telemetry_windows(datagram: bytes):
    """34-byte pktType-0x01 carries the ACK window layout as payload."""
    if len(datagram) < 34 or datagram[6] != PKT_TELEMETRY:
        return None
    video = struct.unpack_from("<H", datagram, 10)[0]
    acked = struct.unpack_from("<H", datagram, 18)[0]
    extra = struct.unpack_from("<H", datagram, 26)[0]
    return video, acked, extra


class AckWindows:
    """Forward-only merge of the three window cursors."""

    def __init__(self) -> None:
        self.acked_data = 0
        self.saw_acked = False
        self.extra = 0
        self.saw_extra = False

    @staticmethod
    def _forward(candidate: int, current: int) -> bool:
        delta = (candidate - current) & 0xFFFF
        return delta != 0 and delta < 0x8000

    def note(self, datagram: bytes) -> None:
        if len(datagram) < 8:
            return
        if datagram[6] == PKT_TELEMETRY:
            win = telemetry_windows(datagram)
            if win:
                _, acked, extra = win
                if not self.saw_acked or acked == self.acked_data or self._forward(
                    acked, self.acked_data
                ):
                    self.acked_data = acked
                    self.saw_acked = True
                self.extra = extra
                self.saw_extra = True
        elif datagram[6] == PKT_ACKED:
            fields = header_fields(datagram)
            if fields:
                seq = fields[2]
                if not self.saw_acked or seq == self.acked_data or self._forward(
                    seq, self.acked_data
                ):
                    self.acked_data = seq
                    self.saw_acked = True
