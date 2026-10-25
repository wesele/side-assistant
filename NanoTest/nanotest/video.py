"""Live-view reassembly + H.264 decode.

The depacketizer is a port of OpenCine `HevcDepacketizer.swift` (Apache-2.0).
Decode is delegated to ffmpeg: access units are Annex-B, which ffmpeg reads
directly from stdin.
"""

from __future__ import annotations

import os
import queue
import shutil
import subprocess
import threading

MAX_ENCODED = 4 * 1024 * 1024


def find_ffmpeg() -> str | None:
    env = os.environ.get("NANOTEST_FFMPEG")
    if env and os.path.isfile(env):
        return env
    return shutil.which("ffmpeg")


class Depacketizer:
    """Reassembles the DJI 16-byte-header picture from pktType-0x02 datagrams."""

    def __init__(self) -> None:
        self.sized = False
        self.expected: int | None = None
        self.buf = bytearray()
        self.last_seq: int | None = None
        self.dropped = 0
        self.pictures = 0

    def reset(self) -> None:
        self.__init__()

    def feed(self, datagram: bytes) -> bytes | None:
        if len(datagram) <= 20 or datagram[6] != 0x02:
            return None
        body = datagram[20:]
        marker = body[:4] == b"\x00\x00\x01\xff"
        declared = None
        if marker and len(body) >= 16:
            count = int.from_bytes(body[4:8], "little")
            if 0 < count <= MAX_ENCODED:
                declared = count + 16
        nonzero = marker and len(body) >= 16 and any(body[4:8])
        if self.sized or nonzero:
            if not self.sized:
                self.sized = True
                self.buf.clear()
            return self._feed_sized(datagram, body, marker, declared)
        return None

    def _feed_sized(self, datagram: bytes, body: bytes, marker: bool, declared: int | None):
        seq = datagram[4] | (datagram[5] << 8)
        if seq == self.last_seq:
            return None
        if marker:
            if self.expected is not None:
                self.dropped += 1
            self.buf.clear()
            self.expected = declared
            self.last_seq = None
        if self.expected is None:
            return None
        if self.last_seq is not None and seq != ((self.last_seq + 8) & 0xFFFF):
            self.dropped += 1
            self.expected = None
            self.buf.clear()
            self.last_seq = seq
            return None
        self.last_seq = seq
        if len(body) > self.expected - len(self.buf):
            self.dropped += 1
            self.expected = None
            self.buf.clear()
            return None
        self.buf += body
        if len(self.buf) != self.expected:
            return None
        access_unit = bytes(self.buf[16:])
        self.buf.clear()
        self.expected = None
        self.pictures += 1
        return access_unit


def split_nals(au: bytes):
    """[(start_code_len, nal_payload)] for every Annex-B NAL."""
    out = []
    i = 0
    n = len(au)
    while i < n - 3:
        if au[i] == 0 and au[i + 1] == 0:
            if au[i + 2] == 1:
                start = i + 3
                out.append((3, start))
                i = start
                continue
            if au[i + 2] == 0 and i + 3 < n and au[i + 3] == 1:
                start = i + 4
                out.append((4, start))
                i = start
                continue
        i += 1
    nals = []
    for index, (sc, start) in enumerate(out):
        end = out[index + 1][1] - out[index + 1][0] if index + 1 < len(out) else n
        payload = au[start:end]
        if payload:
            nals.append((sc, payload))
    return nals


def sanitize_au(au: bytes) -> bytes:
    """Do NOT scan start codes inside the Nano private SEI.

    `06 F0 19` is followed by 25 raw metadata bytes that may contain an
    unescaped `00 00 01` (OpenPocketCine documents this). A blind Annex-B scan
    splits the NAL there and turns the stream into garbage, so the decoder path
    feeds the access unit untouched and lets ffmpeg's own parser handle it.
    """
    return au


class H264Decoder:
    """ffmpeg-backed decoder. Produces RGB24 frames on a callback."""

    def __init__(self, width: int = 1280, height: int = 720, on_frame=None, on_log=None):
        self.width = width
        self.height = height
        self.frame_bytes = width * height * 3
        self.on_frame = on_frame
        self.on_log = on_log
        self.proc: subprocess.Popen | None = None
        self._write_q: queue.Queue = queue.Queue(maxsize=8)
        self._running = False
        self.decode_errors = 0
        self.frames = 0

    @property
    def available(self) -> bool:
        return find_ffmpeg() is not None

    def start(self) -> bool:
        if self.proc is not None:
            return True
        exe = find_ffmpeg()
        if not exe:
            self._log("ffmpeg not found - live view cannot be decoded")
            return False
        cmd = [
            exe, "-hide_banner", "-loglevel", "error",
            # NOTE: -fflags nobuffer / -flags low_delay on a pipe made ffmpeg drop
            # almost every frame (2 of 214 on a real Nano capture). Keep it simple.
            "-probesize", "65536", "-analyzeduration", "0",
            "-threads", "1",
            "-f", "h264", "-i", "pipe:0",
            "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
        ]
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, bufsize=0,
            )
        except OSError as exc:
            self._log(f"ffmpeg start failed: {exc}")
            return False
        self._running = True
        threading.Thread(target=self._reader, daemon=True, name="ffmpeg-out").start()
        threading.Thread(target=self._writer, daemon=True, name="ffmpeg-in").start()
        threading.Thread(target=self._stderr, daemon=True, name="ffmpeg-err").start()
        return True

    def feed(self, access_unit: bytes) -> None:
        if not self._running:
            return
        try:
            self._write_q.put_nowait(sanitize_au(access_unit))
        except queue.Full:
            self._log("decoder backlog - dropping one access unit")

    def stop(self) -> None:
        self._running = False
        proc, self.proc = self.proc, None
        if not proc:
            return
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

    # -- internals -------------------------------------------------------

    def _write(self, data: bytes) -> None:
        if not self.proc or not self.proc.stdin:
            return
        try:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            self._running = False

    def _writer(self) -> None:
        while self._running:
            try:
                au = self._write_q.get(timeout=0.2)
            except queue.Empty:
                continue
            self._write(au)

    def _reader(self) -> None:
        assert self.proc and self.proc.stdout
        out = self.proc.stdout
        buf = bytearray()
        while self._running:
            chunk = out.read(self.frame_bytes - len(buf))
            if not chunk:
                break
            buf += chunk
            if len(buf) >= self.frame_bytes:
                frame = bytes(buf[: self.frame_bytes])
                del buf[: self.frame_bytes]
                self.frames += 1
                if self.on_frame:
                    self.on_frame(frame)

    def _stderr(self) -> None:
        assert self.proc and self.proc.stderr
        for line in iter(self.proc.stderr.readline, b""):
            text = line.decode("utf-8", "replace").strip()
            if text:
                self.decode_errors += 1
                self._log(text[:300])

    def _log(self, message: str) -> None:
        if self.on_log:
            self.on_log(message)
