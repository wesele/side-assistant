"""Wire-level self tests. Run: python -m unittest discover -s tests -v"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest import commands, media, mock, status  # noqa: E402
from nanotest.duml import Frame, crc8, crc16, encode, scan_frames  # noqa: E402
from nanotest.transport import (  # noqa: E402
    ack_payload,
    handshake_payload,
    routing_header,
    transport_header,
)
from nanotest.video import Depacketizer  # noqa: E402


class DumlTests(unittest.TestCase):
    def test_pairing_frame_matches_captured_bytes(self):
        frame = encode(commands.set_pairing_pin(pin="osmo"))
        self.assertEqual(len(frame), 51)
        self.assertEqual(
            list(frame[:11]),
            [0x55, 0x33, 0x04, 0xC2, 0x02, 0x07, 0x92, 0x80, 0x40, 0x07, 0x45],
        )

    def test_roundtrip_and_crc(self):
        original = Frame(0x02, 0x01, 0x1234, 0x40, 0x02, 0x01, b"\x01")
        frames = scan_frames(encode(original))
        self.assertEqual(len(frames), 1)
        got = frames[0]
        self.assertEqual((got.sender, got.receiver, got.seq, got.flags), (2, 1, 0x1234, 0x40))
        self.assertEqual((got.cmd_set, got.cmd_id, got.payload), (0x02, 0x01, b"\x01"))

    def test_bad_crc_is_rejected(self):
        raw = bytearray(encode(commands.shoot_photo()))
        raw[-1] ^= 0xFF
        self.assertEqual(scan_frames(bytes(raw)), [])

    def test_subscription_payload_sizes(self):
        self.assertEqual(len(commands.subscribe("camcap_fov", 0x69DF).payload), 29)
        self.assertEqual(len(commands.subscribe("camcap_base", 0x69DF).payload), 30)
        self.assertEqual(len(commands.subscribe("camcap_video_format", 0x69DF).payload), 38)
        p = commands.subscribe("camcap_fov", 0x69DF).payload
        self.assertEqual(list(p[:4]), [0x02, 0x02, 0x00, 0x00])
        self.assertEqual(list(p[4:8]), [0xDF, 0x69, 0x00, 0x00])
        self.assertEqual(p[11], 10 + 6)

    def test_device_info(self):
        frame = commands.app_device_info(0xA000)
        self.assertEqual(len(frame.payload), 62)
        self.assertEqual(list(frame.payload[:4]), [0x00, 0x41, 0x50, 0x50])
        self.assertEqual(frame.payload[41], 0x02)
        self.assertEqual(frame.payload[50], 0x02)
        self.assertEqual(frame.payload[51], 0x08)
        self.assertEqual(frame.flags, 0x80)
        self.assertEqual(frame.receiver, (2 << 5) | 0x08)

    def test_nano_live_view_recipe(self):
        enable = commands.live_view_enable(receiver=0x41)
        self.assertEqual(enable.receiver, 0x41)
        self.assertEqual((enable.cmd_set, enable.cmd_id), (0x09, 0xA8))
        self.assertEqual(
            list(enable.payload), [0x00, 0x04, 0x02, 0, 0, 0, 0, 0, 0, 0]
        )
        gate = commands.nano_live_gate(True)
        self.assertEqual((gate.cmd_set, gate.cmd_id), (0x02, 0x09))
        self.assertEqual(list(gate.payload), [0] * 10 + [0x03])
        self.assertEqual(commands.nano_live_gate(False).payload[-1], 0x04)

    def test_photo_mode_byte(self):
        self.assertEqual(commands.set_shooting_mode(0x05).payload, b"\x05")
        self.assertEqual(commands.shoot_photo().payload, b"\x01")


class TransportTests(unittest.TestCase):
    def test_handshake_payload(self):
        payload = handshake_payload(0x1238)
        self.assertEqual(len(payload), 40)
        self.assertEqual(payload[0], 0x38)
        self.assertEqual(payload[1], 0x12)
        self.assertEqual(payload[2], 0x64)

    def test_transport_header_xor_and_length(self):
        header = transport_header(0x05, 20, 0xABCD, 0x0040)
        self.assertEqual(len(header), 8)
        self.assertEqual(header[6], 0x05)
        self.assertEqual(header[7] ^ header[0] ^ header[1] ^ header[2] ^ header[3] ^ header[4] ^ header[5] ^ header[6], 0)
        total = header[0] | (header[1] << 8)
        self.assertEqual(total & 0x3FFF, 28)

    def test_routing_header(self):
        r = routing_header(0x0040, 7)
        self.assertEqual(len(r), 12)
        self.assertEqual(r[0] | (r[1] << 8), 0x0038)  # ack = seq - 8
        self.assertEqual(r[2] | (r[3] << 8), 0x0040)
        self.assertEqual(r[8], 7)
        self.assertEqual(r[9], 0x01)

    def test_ack_payload(self):
        p = ack_payload(100, 50, 50)
        self.assertEqual(len(p), 26)
        self.assertEqual(p[0] | (p[1] << 8), 100)
        self.assertEqual(p[8] | (p[9] << 8), 50)
        self.assertEqual(p[16] | (p[17] << 8), 50)


class DepacketizerTests(unittest.TestCase):
    def _packets(self, au: bytes, seq: int = 0x100, frag: int = 1300):
        body = b"\x00\x00\x01\xff" + len(au).to_bytes(4, "little") + b"\x00" * 8 + au
        out = []
        for offset in range(0, len(body), frag):
            chunk = body[offset : offset + frag]
            datagram = bytearray(8)
            datagram[0] = 0x00
            datagram[6] = 0x02
            datagram[4] = seq & 0xFF
            datagram[5] = (seq >> 8) & 0xFF
            seq = (seq + 8) & 0xFFFF
            datagram += bytes(12) + chunk
            out.append((bytes(datagram), seq))
        return out

    def test_reassembles_access_unit(self):
        au = b"\x00\x00\x00\x01\x67" + bytes(range(256)) * 12
        dep = Depacketizer()
        packets = self._packets(au)
        result = None
        for datagram, _ in packets:
            result = dep.feed(datagram)
        self.assertEqual(result, au)
        self.assertEqual(dep.dropped, 0)

    def test_gap_drops_picture(self):
        au = b"\x00\x00\x00\x01\x67" + bytes(range(256)) * 12
        dep = Depacketizer()
        packets = self._packets(au)
        dep.feed(packets[0][0])
        for datagram, _ in packets[2:]:
            dep.feed(datagram)
        self.assertEqual(dep.dropped, 1)


class StatusTests(unittest.TestCase):
    def test_state_push(self):
        payload = bytearray(64)
        payload[0] = 0x80  # recording bit
        payload[57] = 0x05  # photo
        state = status.CameraStatus()
        self.assertTrue(state.apply(Frame(0x02, 0x02, 0, 0, 0x02, 0x80, bytes(payload))))
        self.assertTrue(state.recording)
        self.assertEqual(state.mode_label, "Photo")
        self.assertTrue(state.is_photo)

    def test_battery_push(self):
        payload = bytearray(34)
        payload[20] = 42
        payload[1] = 0x50
        payload[2] = 0x0F  # 3920 mV
        state = status.CameraStatus()
        self.assertTrue(state.apply(Frame(0x02, 0x02, 0, 0, 0x0D, 0x02, bytes(payload))))
        self.assertEqual(state.battery_percent, 42)
        self.assertEqual(state.battery_mv, 3920)

    def test_subscribe_push(self):
        value = bytes([0x10, 0x02, 0x00])
        payload = mock.push_payload("cam_video_param_v2", value)
        parsed = status.parse_subscribe_push(payload)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed[0], "cam_video_param_v2")
        self.assertEqual(parsed[1], value)
        state = status.CameraStatus()
        state.apply(Frame(0x02, 0x02, 0, 0, 0x00, 0x99, payload))
        self.assertEqual(state.resolution_label, "4K 16:9 (3840x2160)")
        self.assertEqual(state.fps, 25)


class MediaTests(unittest.TestCase):
    def test_manifest_roundtrip(self):
        blob = mock.build_manifest(
            [
                mock.build_record("DJI_20261018_101500", "JPG", 0x40000001),
                mock.build_record("DJI_20261018_101600", "JPG", 0x40000002),
            ]
        )
        files = media.decode_manifest(blob, storage=0)
        self.assertEqual(len(files), 2)
        self.assertEqual(files[0].path, "DCIM/DJI_001/DJI_20261018_101500.JPG")
        self.assertEqual(files[0].name, "DJI_20261018_101500.JPG")
        self.assertEqual(files[0].kind, "photo")
        self.assertEqual(files[1].handle, 0x40000002)

    def test_chunk_assembler(self):
        asm = media.MediaChunkAssembler()

        def frame(subtype, body=b"", counter=1):
            header = bytes([0x4A, subtype, 0, 0, counter, 0, 0, 0, 0, 0])
            return Frame(0x00, 0x02, 0, 0, 0x00, 0x27, header + body)

        asm.ingest(frame(0x04))
        asm.ingest(frame(0x01, b"abc"))
        asm.ingest(frame(0x01, b"def"))
        asm.ingest(frame(0x03))
        self.assertEqual(bytes(asm.data[1]), b"abcdef")
        self.assertTrue(asm.closed(1))

    def test_media_url(self):
        url = media.media_url("192.168.2.1", 0, "DCIM/DJI_001/A.JPG")
        self.assertTrue(url.startswith("http://192.168.2.1/v2?"))
        self.assertIn("storage=0", url)
        self.assertIn("path=DCIM/DJI_001/A.JPG", url)


if __name__ == "__main__":
    unittest.main(verbosity=2)
