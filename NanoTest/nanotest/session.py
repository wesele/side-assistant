"""Session orchestration: connect, live view, stills, media.

Everything runs on one asyncio loop in a worker thread; the GUI talks to it
through `call_soon_threadsafe` and receives events from a queue.
"""

from __future__ import annotations

import asyncio
import os
import time

from . import commands, media, wifi
from .datalink import Datalink
from .duml import Frame
from .status import CameraStatus
from .video import Depacketizer, H264Decoder

CAPTURE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "captures")


class NanoSession:
    def __init__(self, emit, loop: asyncio.AbstractEventLoop):
        self.emit = emit
        self.loop = loop
        self.status = CameraStatus()
        self.datalink: Datalink | None = None
        self.depacketizer = Depacketizer()
        self.decoder: H264Decoder | None = None
        self.connected = False
        self.live = False
        self.host = wifi.CAMERA_HOST
        self.media_host = wifi.CAMERA_HOST
        self.local_ip = ""
        self.media_files: list[media.MediaFile] = []
        self._assembler = media.MediaChunkAssembler()
        self._assembler_active = False
        self._waiters: dict[int, list[asyncio.Future]] = {}
        self._last_status_emit = 0.0
        self._frame_times: list[float] = []
        self._first_picture_task = None

    # -- plumbing --------------------------------------------------------

    def log(self, message: str) -> None:
        self.emit("log", message)

    def _status_dirty(self) -> None:
        now = time.time()
        if now - self._last_status_emit >= 0.25:
            self._last_status_emit = now
            self.emit("status", self.status)

    def _on_frame(self, frame: Frame) -> None:
        key = frame.key
        if self.status.apply(frame):
            self._status_dirty()
        if self._assembler_active:
            self._assembler.ingest(frame)
        waiters = self._waiters.pop(key, [])
        for fut in waiters:
            if not fut.done():
                fut.set_result(frame)

    def _on_video(self, datagram: bytes) -> None:
        au = self.depacketizer.feed(datagram)
        if au and self.decoder:
            self.decoder.feed(au)

    def _on_decoded(self, rgb: bytes) -> None:
        now = time.time()
        self._frame_times.append(now)
        if len(self._frame_times) > 50:
            del self._frame_times[:-50]
        self.emit("frame", rgb)

    async def _wait(self, key: int, timeout: float = 3.0):
        fut = self.loop.create_future()
        self._waiters.setdefault(key, []).append(fut)
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            return None

    def measured_fps(self) -> float:
        if len(self._frame_times) < 2:
            return 0.0
        span = self._frame_times[-1] - self._frame_times[0]
        if span <= 0:
            return 0.0
        return (len(self._frame_times) - 1) / span

    # -- connect ---------------------------------------------------------

    async def connect_direct(
        self, host: str = wifi.CAMERA_HOST, local_ip: str = "", media_host: str = "",
        capture_path: str = "",
    ) -> bool:
        self.host = host
        self.media_host = media_host or host
        self.emit("state", f"connecting {host}")
        local_ip = local_ip or wifi.local_ip_for(host)
        self.local_ip = local_ip
        self.log(f"local interface {local_ip or 'auto'}")
        self.datalink = Datalink(
            host,
            on_frame=self._on_frame,
            on_video=self._on_video,
            on_log=self.log,
            tcp_poke=True,
            capture_path=capture_path,
        )
        ok = await self.datalink.open(local_ip=local_ip)
        self.connected = ok
        self.emit("state", "connected" if ok else "no datalink")
        return ok

    async def connect_via_wifi(self, ssid: str, password: str) -> bool:
        self.emit("state", f"joining {ssid}")
        ok, ip = await self.loop.run_in_executor(
            None, lambda: wifi.join(ssid, password, 25.0, self.log)
        )
        if not ok:
            self.emit("state", "Wi-Fi join failed")
            return False
        return await self.connect_direct(wifi.CAMERA_HOST, ip)

    # -- live ------------------------------------------------------------

    async def start_live(self) -> bool:
        if not self.datalink or not self.connected:
            self.log("not connected")
            return False
        if not self.decoder:
            self.decoder = H264Decoder(
                on_frame=self._on_decoded, on_log=lambda m: self.log(f"decode: {m}")
            )
        if not self.decoder.start():
            return False
        self.depacketizer.reset()
        # Nano recipe: gate first, then the enable with receiver 0x41.
        self.datalink.send(commands.nano_live_gate(True))
        await asyncio.sleep(0.12)
        self.datalink.send(commands.live_view_enable(receiver=0x41))
        self.live = True
        self.emit("state", "live")
        self.log("live view enable sent (0x09/A8 rcv=0x41)")
        self._first_picture_task = asyncio.create_task(self._first_picture_watch())
        return True

    async def _first_picture_watch(self) -> None:
        """One bounded retry if the first IDR never lands (a lost burst costs SPS/PPS)."""
        deadline = self.loop.time() + 3.0
        while self.loop.time() < deadline:
            if self.decoder and self.decoder.frames > 0:
                return
            await asyncio.sleep(0.2)
        if not self.connected or not self.live:
            return
        self.log("no picture after 3 s - re-sending live enable once (fresh IDR)")
        self.datalink.send(commands.nano_live_gate(True))
        await asyncio.sleep(0.1)
        self.datalink.send(commands.live_view_enable(receiver=0x41))

    async def stop_live(self) -> None:
        if self._first_picture_task:
            self._first_picture_task.cancel()
            self._first_picture_task = None
        if self.datalink and self.connected:
            self.datalink.send(commands.nano_live_gate(False))
        if self.decoder:
            self.decoder.stop()
            self.decoder = None
        self.live = False
        self.emit("state", "connected")

    async def reenable_live(self) -> None:
        """Second enable after a stall; never loop this - it resets the GOP clock."""
        if self.datalink and self.connected:
            self.datalink.send(commands.nano_live_gate(True))
            await asyncio.sleep(0.1)
            self.datalink.send(commands.live_view_enable(receiver=0x41))
            self.log("live view re-enable sent (IDR request)")

    # -- stills ----------------------------------------------------------

    async def set_mode(self, mode_byte: int) -> None:
        if not self.datalink:
            return
        self.datalink.send(commands.set_shooting_mode(mode_byte))
        self.log(f"shooting mode SET 0x{mode_byte:02X}")
        # 0x02/0x80 @57 echoes the mode; give the body up to 2.5 s to report it.
        deadline = self.loop.time() + 2.5
        while self.loop.time() < deadline:
            if self.status.mode_byte == mode_byte:
                self.log("mode confirmed by camera status")
                return True
            await asyncio.sleep(0.1)
        self.log(f"mode not confirmed (camera reports 0x{self.status.mode_byte:02X})")
        return False

    async def take_photo(self, download: bool = True) -> str | None:
        if not self.datalink or not self.connected:
            self.log("not connected")
            return None
        if not self.status.is_photo:
            await self.set_mode(0x05)
        self.log("shutter 0x02/0x01 [01]")
        self.datalink.send(commands.shoot_photo())
        ack = await self._wait(0x0201, timeout=3.0)
        if ack:
            self.log(f"shutter reply {ack.payload.hex(' ').upper() or '-'}")
        else:
            self.log("shutter: no reply (camera may still have fired)")
        await asyncio.sleep(1.0)  # card write + manifest
        before = {f.path for f in self.media_files}
        newest = None
        deadline = self.loop.time() + 6.0
        while self.loop.time() < deadline:
            files = await self.list_media()
            photos = [f for f in files if f.is_photo]
            fresh = [f for f in photos if f.path not in before]
            if fresh or (photos and not before):
                newest = max(fresh or photos, key=lambda f: f.name)
                break
            await asyncio.sleep(0.8)
        if newest is None:
            self.log("no new still appeared in the media list")
            return None
        self.log(f"newest still: {newest.path} ({newest.size_bytes} B)")
        if not download:
            return newest.path
        dest = await self.loop.run_in_executor(
            None, lambda: media.fetch_media(self.media_host, newest, CAPTURE_DIR, self._progress)
        )
        self.log(f"saved {dest}")
        self.emit("photo_saved", dest)
        return dest

    def _progress(self, done: int, total: int) -> None:
        if total:
            self.emit("progress", (done, total))

    async def list_media(self) -> list[media.MediaFile]:
        if not self.datalink or not self.connected:
            return []
        self._assembler = media.MediaChunkAssembler()
        self._assembler_active = True
        try:
            self.datalink.send(commands.media_list(1, 0x00000001))
            self.datalink.send(commands.media_list_trigger())
            self.datalink.send(commands.media_list(2, 0x40000001))
            self.datalink.send(commands.media_list_trigger())
            deadline = self.loop.time() + 6.0
            started = self.loop.time()
            while self.loop.time() < deadline:
                await asyncio.sleep(0.15)
                if self._assembler.closed(1) and self._assembler.closed(2):
                    break
                # A body without internal storage may never answer counter 2.
                if (
                    self._assembler.closed(1)
                    and not self._assembler.data.get(2)
                    and self.loop.time() - started > 2.0
                ):
                    break
            files: list[media.MediaFile] = []
            for counter, storage in ((1, 0), (2, 1)):
                data = bytes(self._assembler.data.get(counter, b""))
                if data:
                    files.extend(media.decode_manifest(data, storage=storage))
        finally:
            self._assembler_active = False
        self.media_files = files
        self.emit("media", files)
        self.log(f"media list: {len(files)} item(s)")
        return files

    async def download(self, file: media.MediaFile) -> str:
        dest = await self.loop.run_in_executor(
            None, lambda: media.fetch_media(self.media_host, file, CAPTURE_DIR, self._progress)
        )
        self.log(f"saved {dest}")
        self.emit("photo_saved", dest)
        return dest

    # -- shutdown --------------------------------------------------------

    async def disconnect(self) -> None:
        await self.stop_live()
        if self.datalink:
            await self.datalink.close()
        self.datalink = None
        self.connected = False
        self.emit("state", "idle")
        self.log("disconnected")
