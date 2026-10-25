"""A fake Osmo Nano on localhost, for testing the app without hardware.

Speaks the same datalink (UDP 9004), TCP 7001 poke, a tiny HTTP `/v2` server and
the DUML command surface the app uses: handshake, registration, live view,
shutter, media list and status pushes.
"""

from __future__ import annotations

import asyncio
import os
import random
import shutil
import subprocess
import time
import urllib.parse

from .duml import Frame, encode, scan_frames
from .status import parse_subscribe_push
from .video import find_ffmpeg

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")


# --------------------------------------------------------------------------
# H.264 test asset + access-unit split
# --------------------------------------------------------------------------


def ensure_test_video(path: str | None = None) -> str | None:
    path = path or os.path.join(ASSETS, "testsrc.h264")
    if os.path.isfile(path) and os.path.getsize(path) > 10000:
        return path
    exe = find_ffmpeg()
    if not exe:
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cmd = [
        exe, "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25",
        "-t", "8", "-c:v", "libx264", "-profile:v", "baseline",
        "-pix_fmt", "yuv420p", "-g", "25", "-bf", "0", "-f", "h264", path,
    ]
    subprocess.run(cmd, check=False, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return path if os.path.isfile(path) else None


def _start_codes(data: bytes):
    """Yield (position, length) for each Annex-B start code."""
    i = 0
    n = len(data)
    while i < n - 3:
        if data[i] == 0 and data[i + 1] == 0:
            if data[i + 2] == 1:
                yield i, 3
                i += 3
                continue
            if data[i + 2] == 0 and i + 3 < n and data[i + 3] == 1:
                yield i, 4
                i += 4
                continue
        i += 1


def split_access_units(data: bytes) -> list[bytes]:
    """Group NALs so each AU ends when a new VCL NAL starts."""
    codes = list(_start_codes(data))
    if not codes:
        return []
    nals: list[bytes] = []
    for index, (pos, sc_len) in enumerate(codes):
        end = codes[index + 1][0] if index + 1 < len(codes) else len(data)
        nals.append(data[pos + sc_len : end])
    units: list[list[bytes]] = []
    current: list[bytes] = []
    has_vcl = False
    for nal in nals:
        if not nal:
            continue
        nal_type = nal[0] & 0x1F
        is_vcl = nal_type in (1, 5)
        if is_vcl and has_vcl:
            units.append(current)
            current = []
            has_vcl = False
        current.append(nal)
        if is_vcl:
            has_vcl = True
    if current:
        units.append(current)
    return [b"".join(b"\x00\x00\x00\x01" + nal for nal in unit) for unit in units]


# --------------------------------------------------------------------------
# Manifest construction (Record TLV the app's parser expects)
# --------------------------------------------------------------------------


def _path_field(path: str, sub: int) -> bytes:
    raw = path.encode("latin-1")
    return bytes([0x1A, len(raw) + 6, 0, 0, 0, sub]) + raw


def build_record(stem: str, ext: str, handle: int) -> bytes:
    """One CompositePack record.

    The real manifest puts the DCIM path *last*: the 8-byte handle block and the
    `03 ff 19 06` marker sit 17/9 bytes before the path field, which is what
    `resolveRecord` anchors on.
    """
    name = f"{stem}.{ext}"
    record = bytearray()
    record += _path_field(f"MISC/THM/DJI_001/{stem}", 2)
    record += bytes([0x0D, len(name)]) + name.encode("latin-1")
    record += b"\x00\x00\x00\x00"  # keeps the still-size read at zero
    record += handle.to_bytes(4, "little") + b"\x00" * 4 + b"\x03\xff\x19\x06" + b"\x00" * 5
    record += _path_field(f"DCIM/DJI_001/{stem}", 1)
    return bytes(record)


def build_manifest(records: list[bytes]) -> bytes:
    body = b"".join(records)
    header = len(records).to_bytes(4, "little")
    return header + body


def push_payload(name: str, value: bytes) -> bytes:
    nb = name.encode()
    p = bytearray([0x02, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0, 0, 0])
    inner = 2 + len(nb) + 6 + 2 + len(value)
    p += bytes([inner & 0xFF, (inner >> 8) & 0xFF])
    p += bytes([len(nb) & 0xFF, (len(nb) >> 8) & 0xFF])
    p += nb
    p += b"\x00" * 6
    p += bytes([len(value) & 0xFF, (len(value) >> 8) & 0xFF])
    p += value
    return bytes(p)


# --------------------------------------------------------------------------


class MockCamera:
    def __init__(self, host: str = "127.0.0.1", port: int = 9004, http_port: int = 8080, log=None):
        self.host = host
        self.port = port
        self.http_port = http_port
        self.log = log or (lambda m: None)
        self.transport: asyncio.DatagramTransport | None = None
        self.session = random.randint(0x1000, 0xFFFE)
        self.seq = 0
        self.mode = 0x01
        self.recording = False
        self.live = False
        self.battery = 87
        self.sd_total_mb = 119_000
        self.sd_free_mb = 96_400
        self.internal_total_mb = 107_000
        self.internal_free_mb = 88_000
        self.elapsed = 0
        self.units: list[bytes] = []
        self._photo_jpeg = os.path.join(ASSETS, "still.jpg")
        self._media: list[dict] = []
        self._tasks: list[asyncio.Task] = []

    # -- lifecycle -------------------------------------------------------

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        self.transport, _ = await loop.create_datagram_endpoint(
            lambda: _Udp(self._on_datagram), local_addr=(self.host, self.port)
        )
        self._tasks.append(asyncio.create_task(asyncio.start_server(
            self._tcp_client, self.host, 7001)))
        self._tasks.append(asyncio.create_task(asyncio.start_server(
            self._http_client, self.host, self.http_port)))
        self._tasks.append(asyncio.create_task(self._status_loop()))
        self._tasks.append(asyncio.create_task(self._video_loop()))
        self.log(f"mock camera on udp {self.host}:{self.port}, http :{self.http_port}")

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        self._tasks.clear()
        if self.transport:
            self.transport.close()

    # -- wire ------------------------------------------------------------

    def _send_frame(self, frame: Frame) -> None:
        if not self.transport or not self.peer[1]:
            return
        from .transport import PKT_ACKED, transport_header

        duml = encode(frame)
        packet = transport_header(PKT_ACKED, len(duml), self.session, self.seq) + duml
        self.seq = (self.seq + 8) & 0xFFFF
        self._safe_send(packet)

    def _safe_send(self, packet: bytes) -> None:
        """Never send to port 0: Windows turns the ICMP error into a dead socket."""
        if not self.transport or not self.peer[1]:
            return
        try:
            self.transport.sendto(packet, (self.peer[0], self.peer[1]))  # type: ignore[union-attr]
        except OSError:
            pass

    peer = ("127.0.0.1", 0)

    def _reply(self, cmd_set: int, cmd_id: int, payload: bytes = b"\x00") -> None:
        self._send_frame(Frame(0x02, 0x02, 0, 0xC0, cmd_set, cmd_id, payload))

    def _on_datagram(self, data: bytes, addr) -> None:
        if len(data) < 8:
            return
        self.peer = (addr[0], addr[1])
        if data[6] == 0x00:
            from .transport import PKT_TELEMETRY, ack_payload, handshake_datagram, transport_header

            reply = handshake_datagram(self.session, self.seq, 0x1000)
            self.transport.sendto(reply, self.peer)  # type: ignore[union-attr]
            # Initial command window, like a real body: 34-byte pktType 0x01.
            window = ack_payload(0x0FF8, 0x0FF8, 0x0FF8)
            initial = transport_header(PKT_TELEMETRY, len(window), self.session, self.seq) + window
            self.seq = (self.seq + 8) & 0xFFFF
            self._safe_send(initial)
            return
        for frame in scan_frames(data):
            self._handle(frame)

    def _handle(self, frame: Frame) -> None:
        key = (frame.cmd_set, frame.cmd_id)
        if key == (0x09, 0xA8):
            self.live = True
            self._reply(0x09, 0xA8)
            self.log("mock: live view enabled")
        elif key == (0x02, 0x09):
            payload = frame.payload
            if payload and payload[-1] == 0x04:
                self.live = False
            self._reply(0x02, 0x09)
        elif key == (0x02, 0xE1):
            if frame.payload:
                self.mode = frame.payload[0]
            self._reply(0x02, 0xE1)
            self._push_state()
        elif key == (0x02, 0x01):
            self._reply(0x02, 0x01)
            if self.mode == 0x05:
                self._capture_still()
        elif key == (0x02, 0x02):
            self.recording = bool(frame.payload and frame.payload[0])
            self._reply(0x02, 0x02)
        elif key == (0x00, 0x26):
            counter = frame.payload[4] if len(frame.payload) > 4 else 1
            self._send_manifest(counter)
        elif key == (0x02, 0x0C):
            self._reply(0x02, 0x0C)
        elif key == (0x00, 0x81) or key == (0x00, 0x88) or key == (0x00, 0x99):
            pass
        else:
            self._reply(*key)

    def _push_state(self) -> None:
        p = bytearray(64)
        flags = 0x0000_0080 if self.recording else 0
        p[0:4] = flags.to_bytes(4, "little")
        p[5:9] = self.sd_total_mb.to_bytes(4, "little")
        p[9:13] = self.sd_free_mb.to_bytes(4, "little")
        p[17:21] = (3600).to_bytes(4, "little")
        p[29:31] = (self.elapsed & 0xFFFF).to_bytes(2, "little")
        p[57] = self.mode
        self._send_frame(Frame(0x02, 0x02, 0, 0x00, 0x02, 0x80, bytes(p)))

    def _push_status(self) -> None:
        battery = bytearray(34)
        battery[20] = self.battery
        battery[1:3] = (3920).to_bytes(2, "little")
        battery[32] = 0
        self._send_frame(Frame(0x02, 0x02, 0, 0x00, 0x0D, 0x02, bytes(battery)))

        storage = bytearray(32)
        storage[6:10] = self.sd_total_mb.to_bytes(4, "little")
        storage[10:14] = self.sd_free_mb.to_bytes(4, "little")
        storage[24:28] = self.internal_total_mb.to_bytes(4, "little")
        storage[28:32] = self.internal_free_mb.to_bytes(4, "little")
        self._send_frame(Frame(0x02, 0x02, 0, 0x00, 0x02, 0xDC, bytes(storage)))

        expo = bytearray(24)
        expo[7] = 0x01  # auto
        expo[20] = 50
        expo[21] = 0x80
        expo[22] = 0x00
        expo[5] = 0x03  # ISO index 100
        expo[16:18] = (100).to_bytes(2, "little")
        expo[6] = 16
        expo[15] = 16
        self._push("cam_expo_param", bytes(expo))
        self._push("cam_video_param_v2", bytes([0x10, 0x02, 0x00]))
        self._push("cam_image_effect", bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x0E, 0x00, 0x00]))
        self._push("cam_record_time", self.elapsed.to_bytes(4, "little"))
        self._push("timecode_info", bytes([0, 0, 0, 0, 22, 47, 18, 0]))
        self._push("camcap_photo_storage_format", bytes([0x01]))

    def _push(self, name: str, value: bytes) -> None:
        self._send_frame(Frame(0x02, 0x02, 0, 0x00, 0x00, 0x99, push_payload(name, value)))

    async def _status_loop(self) -> None:
        while True:
            self._push_state()
            self._push_status()
            if self.recording:
                self.elapsed += 1
            await asyncio.sleep(1.0)

    # -- media -----------------------------------------------------------

    def _capture_still(self) -> None:
        os.makedirs(ASSETS, exist_ok=True)
        name = time.strftime("DJI_%Y%m%d_%H%M%S")
        dest = os.path.join(ASSETS, f"{name}.JPG")
        self._make_jpeg(dest, name)
        self._media.append({"stem": name, "ext": "JPG", "handle": 0x40000000 | (len(self._media) + 1),
                            "file": dest, "storage": 0})
        self.log(f"mock: still captured -> {name}.JPG")

    def _make_jpeg(self, dest: str, label: str) -> None:
        try:
            from PIL import Image, ImageDraw
        except ImportError:
            shutil.copyfile(self._photo_jpeg, dest) if os.path.isfile(self._photo_jpeg) else open(dest, "wb").write(b"")
            return
        image = Image.new("RGB", (1280, 960), (18, 24, 32))
        draw = ImageDraw.Draw(image)
        for y in range(0, 960, 4):
            shade = int(30 + 120 * y / 960)
            draw.line([(0, y), (1280, y)], fill=(shade // 2, shade, shade // 3))
        draw.rectangle([60, 60, 1220, 900], outline=(240, 200, 90), width=6)
        draw.text((90, 110), "NanoTest mock still", fill=(255, 255, 255))
        draw.text((90, 150), label, fill=(255, 255, 255))
        image.save(dest, "JPEG", quality=85)

    def _send_manifest(self, counter: int) -> None:
        from .transport import PKT_ACKED, transport_header

        records = []
        for item in self._media:
            if item["storage"] == (0 if counter == 1 else 1):
                records.append(build_record(item["stem"], item["ext"], item["handle"]))
        blob = build_manifest(records) if records else b""
        counter_byte = counter & 0xFF

        def chunk_frame(subtype: int, body: bytes = b"") -> bytes:
            header = bytes([0x4A, subtype, 0x00, 0x00, counter_byte, 0, 0, 0, 0, 0])
            frame = Frame(0x02, 0x02, 0, 0x00, 0x00, 0x27, header + body)
            duml = encode(frame)
            return transport_header(PKT_ACKED, len(duml), self.session, self.seq) + duml

        def send(packet: bytes) -> None:
            self.seq = (self.seq + 8) & 0xFFFF
            self._safe_send(packet)

        send(chunk_frame(0x04))
        if blob:
            for offset in range(0, len(blob), 900):
                send(chunk_frame(0x01, blob[offset : offset + 900]))
                time.sleep(0)
        send(chunk_frame(0x03))

    # -- video -----------------------------------------------------------

    async def _video_loop(self) -> None:
        path = ensure_test_video()
        if not path:
            self.log("mock: no ffmpeg, live view will be black")
            return
        with open(path, "rb") as handle:
            self.units = split_access_units(handle.read())
        self.log(f"mock: {len(self.units)} test pictures loaded")
        index = 0
        while True:
            await asyncio.sleep(1 / 25)
            if not self.live or not self.units or not self.transport:
                continue
            unit = self.units[index % len(self.units)]
            index += 1
            self._send_picture(unit)

    def _send_picture(self, unit: bytes) -> None:
        from .transport import PKT_VIDEO, transport_header

        header = b"\x00\x00\x01\xff" + len(unit).to_bytes(4, "little") + b"\x00" * 8
        body = header + unit
        group = 0
        frag = 0
        for offset in range(0, len(body), 1200):
            chunk = body[offset : offset + 1200]
            frag_header = bytes([group & 0xFF, 0x0E, frag & 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            packet = (
                transport_header(PKT_VIDEO, len(frag_header) + len(chunk), self.session, self.seq)
                + frag_header
                + chunk
            )
            self.seq = (self.seq + 8) & 0xFFFF
            self._safe_send(packet)
            frag += 1
            if frag >= 63:
                frag = 0
                group += 1

    # -- tcp / http ------------------------------------------------------

    async def _tcp_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.log("mock: TCP 7001 poked")
        try:
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                for frame in scan_frames(data):
                    self.log(f"mock: TCP frame {frame.cmd_set:02X}/{frame.cmd_id:02X}")
        except Exception:
            pass
        finally:
            writer.close()

    async def _http_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            request = await reader.readline()
            if not request:
                return
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
            target = request.decode("latin-1").split(" ")[1]
            parsed = urllib.parse.urlparse(target)
            query = urllib.parse.parse_qs(parsed.query)
            path = query.get("path", [""])[0]
            name = path.rsplit("/", 1)[-1]
            local = os.path.join(ASSETS, name)
            if os.path.isfile(local):
                with open(local, "rb") as handle:
                    blob = handle.read()
                writer.write(
                    b"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n"
                    + f"Content-Length: {len(blob)}\r\nConnection: close\r\n\r\n".encode()
                    + blob
                )
            else:
                writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass


class _Udp(asyncio.DatagramProtocol):
    def __init__(self, on_datagram) -> None:
        self.on_datagram = on_datagram

    def datagram_received(self, data, addr) -> None:  # noqa: ANN001
        self.on_datagram(data, addr)

    def connection_made(self, transport) -> None:  # noqa: ANN001
        pass
