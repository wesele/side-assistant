"""UDP 9004 DUML datalink: TCP 7001 poke, handshake, registration, window ACK.

Ported from OpenCine `DjiAppleDatalink.swift`, Apache-2.0.

Wire facts that matter:
  * handshake: pktType 0x00, 40-byte payload whose first u16 is an 8-aligned base seq
  * every datagram carries an 8-byte transport header; DUML commands add a 12-byte
    routing header and ride pktType 0x05
  * window ACK (pktType 0x04) must run at ~40 Hz; group 0 is the latest video seq
  * registration (0x00/0x81 + 0x00/0x88) must repeat ~1 Hz or video stops after ~8 s
"""

from __future__ import annotations

import asyncio
import random
import socket
import struct

from . import commands
from .duml import Frame, encode, scan_frames
from .transport import (
    PKT_ACK,
    PKT_TELEMETRY,
    PKT_VIDEO,
    AckWindows,
    ack_datagram,
    handshake_datagram,
    routing_header,
    transport_header,
)

DEFAULT_PORT = 9004
TCP_POKE_PORT = 7001


class _Protocol(asyncio.DatagramProtocol):
    def __init__(self, on_datagram) -> None:
        self.on_datagram = on_datagram
        self.error = None

    def datagram_received(self, data, addr) -> None:  # noqa: ANN001
        self.on_datagram(data)

    def error_received(self, exc) -> None:  # noqa: ANN001
        self.error = exc


class Datalink:
    def __init__(
        self,
        host: str,
        port: int = DEFAULT_PORT,
        on_frame=None,
        on_video=None,
        on_log=None,
        tcp_poke: bool = True,
        capture_path: str = "",
    ) -> None:
        self.host = host
        self.port = port
        self.on_frame = on_frame
        self.on_video = on_video
        self.on_log = on_log
        self.tcp_poke = tcp_poke
        self._capture = open(capture_path, "wb") if capture_path else None
        self.capture_path = capture_path

        self.transport: asyncio.DatagramTransport | None = None
        self._tcp_writer: asyncio.StreamWriter | None = None
        self._tasks: list[asyncio.Task] = []

        self.session_id = 0
        self.base_seq = 0
        self.udp_seq = 0
        self.duml_seq = 0xA000
        self.cmd_counter = 0

        self.windows = AckWindows()
        self.last_video_seq = 0
        self.video_packets = 0
        self.connected = False
        self.initial_window_seq: int | None = None
        self._handshake_ack = asyncio.Event()

    # -- lifecycle -------------------------------------------------------

    def _log(self, message: str) -> None:
        if self.on_log:
            self.on_log(message)

    async def open(self, local_ip: str = "", timeout: float = 25.0) -> bool:
        loop = asyncio.get_running_loop()
        self.session_id = random.randint(0x1000, 0xFFFE)
        self.base_seq = random.randint(0x1000, 0xF000) & 0xFFF8

        if self.tcp_poke and local_ip:
            await self._poke_tcp(local_ip)

        bind_ip = local_ip or "0.0.0.0"
        try:
            self.transport, _ = await loop.create_datagram_endpoint(
                lambda: _Protocol(self._on_datagram), local_addr=(bind_ip, 0)
            )
        except OSError as exc:
            self._log(f"UDP bind {bind_ip}:0 failed: {exc}")
            return False
        # A live-view IDR is ~95 KB and arrives as one burst when the encoder is
        # enabled. Windows' default 64 KB receive buffer drops the first packets,
        # which costs the SPS/PPS and kills decoding until the next IDR.
        try:
            sock = self.transport.get_extra_info("socket")
            if sock is not None:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
                self._log(f"UDP receive buffer {sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)} B")
        except OSError as exc:
            self._log(f"could not raise SO_RCVBUF: {exc}")
        self._log(f"UDP bound to {bind_ip}:{self.transport.get_extra_info('sockname')[1]} -> "
                  f"{self.host}:{self.port}")

        deadline = loop.time() + timeout
        attempt = 0
        while loop.time() < deadline:
            attempt += 1
            packet = handshake_datagram(self.session_id, self.udp_seq, self.base_seq)
            self.transport.sendto(packet, (self.host, self.port))
            self.udp_seq = (self.udp_seq + 8) & 0xFFFF
            try:
                await asyncio.wait_for(self._handshake_ack.wait(), timeout=0.35)
                break
            except asyncio.TimeoutError:
                if attempt % 5 == 0:
                    self._log(f"handshake attempt {attempt}: no reply yet")

        if not self._handshake_ack.is_set():
            self._log("handshake never acknowledged")
            return False

        self._log(f"handshake ACK (session 0x{self.session_id:04X})")
        # The camera's first 34-byte pktType-0x01 datagram advertises the command
        # window. Our first command must continue from it, not from our own base:
        # a wrong sequence silently drops writes while reads keep flowing.
        deadline = loop.time() + 1.5
        while loop.time() < deadline and self.initial_window_seq is None:
            await asyncio.sleep(0.02)
        if self.initial_window_seq is not None:
            self.udp_seq = self.initial_window_seq
            self._log(f"initial command window 0x{self.udp_seq:04X}")
        else:
            self.udp_seq = self.base_seq
            self._log("no initial window; using base seq")
        self.windows = AckWindows()
        self._send_ack()

        self.send(commands.app_device_info(self.duml_seq))
        self.connected = True
        self._tasks.append(asyncio.create_task(self._ack_pump()))
        self._tasks.append(asyncio.create_task(self._registration_loop()))
        self._tasks.append(asyncio.create_task(self._subscribe_loop()))
        return True

    async def _poke_tcp(self, local_ip: str) -> None:
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, TCP_POKE_PORT, local_addr=(local_ip, 0)),
                timeout=4.0,
            )
        except (OSError, asyncio.TimeoutError) as exc:
            self._log(f"TCP {TCP_POKE_PORT} poke skipped ({exc})")
            return
        self._tcp_writer = writer
        writer.write(encode(commands.set_pairing_pin()))
        await writer.drain()
        # Keep the socket open for the session: closing it RSTs the camera.
        self._tasks.append(asyncio.create_task(self._drain_poke(reader)))
        self._log(f"TCP {TCP_POKE_PORT} poke sent")

    async def _drain_poke(self, reader: asyncio.StreamReader) -> None:
        try:
            while True:
                data = await reader.read(4096)
                if not data:
                    break
        except Exception:
            pass

    async def close(self) -> None:
        self.connected = False
        for task in self._tasks:
            task.cancel()
        self._tasks.clear()
        if self.transport:
            self.transport.close()
            self.transport = None
        if self._tcp_writer:
            try:
                self._tcp_writer.close()
            except Exception:
                pass
            self._tcp_writer = None
        if self._capture:
            self._capture.close()
            self._capture = None
            self._log(f"capture written to {self.capture_path}")
        self._log("datalink closed")

    # -- send ------------------------------------------------------------

    def send(self, frame: Frame) -> int:
        if not self.transport:
            return 0
        frame.seq = self.duml_seq
        seq = frame.seq
        self.duml_seq = (self.duml_seq + 1) & 0xFFFF
        routing = routing_header(self.udp_seq, self.cmd_counter)
        self.cmd_counter = (self.cmd_counter + 1) & 0xFF
        duml = encode(frame)
        payload = routing + duml
        packet = transport_header(0x05, len(payload), self.session_id, self.udp_seq) + payload
        self.transport.sendto(packet, (self.host, self.port))
        self.udp_seq = (self.udp_seq + 8) & 0xFFFF
        return seq

    def _send_ack(self) -> None:
        if not self.transport:
            return
        acked = self.windows.acked_data if self.windows.saw_acked else self.base_seq
        extra = self.windows.extra if self.windows.saw_extra else self.base_seq
        packet = ack_datagram(self.session_id, self.last_video_seq, acked, extra)
        self.transport.sendto(packet, (self.host, self.port))

    async def _ack_pump(self) -> None:
        # Mimo ACKs at ~41 Hz; 1 Hz stalls the camera's window once live view flows.
        while True:
            await asyncio.sleep(0.025)
            self._send_ack()

    async def _registration_loop(self) -> None:
        # Without this the camera stops sending video ~8-10 s after the last one.
        while True:
            self.send(commands.app_device_info(self.duml_seq))
            self.send(commands.app_presence_frame(self.duml_seq))
            await asyncio.sleep(1.0)

    async def _subscribe_loop(self) -> None:
        sub_id = commands.FIRST_SUB_ID
        for key in commands.SUBSCRIPTION_KEYS:
            self.send(commands.subscribe(key, sub_id))
            sub_id += 1
            await asyncio.sleep(0.02)
        self._log(f"subscribed {len(commands.SUBSCRIPTION_KEYS)} status keys")

    # -- receive ---------------------------------------------------------

    def _on_datagram(self, data: bytes) -> None:
        if len(data) < 8:
            return
        pkt = data[6]
        if pkt == PKT_VIDEO:
            self.last_video_seq = data[4] | (data[5] << 8)
            self.video_packets += 1
            if self._capture:
                self._capture.write(len(data).to_bytes(4, "little"))
                self._capture.write(data)
            if self.on_video:
                self.on_video(data)
            return
        if pkt == 0x00:
            self._handshake_ack.set()
            return
        if pkt == PKT_TELEMETRY and len(data) == 34 and self.initial_window_seq is None:
            self.initial_window_seq = ((data[8] | (data[9] << 8)) + 8) & 0xFFFF
        if pkt in (PKT_TELEMETRY, 0x03):
            self.windows.note(data)
        for frame in scan_frames(data):
            if self.on_frame:
                self.on_frame(frame)

    def stats(self) -> dict:
        return {
            "video_packets": self.video_packets,
            "last_video_seq": self.last_video_seq,
            "udp_seq": self.udp_seq,
            "duml_seq": self.duml_seq,
        }
