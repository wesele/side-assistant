"""BLE-only session: status, mode switch and shutter without Wi-Fi.

Verified on an Osmo Nano (2026-10-18): over GATT alone the camera answered
`0x02/0xE1 [05]` with `00`, reported mode byte 5 in `0x02/0x80`, and answered
`0x02/0x01 [01]` with `00`. What BLE cannot do is deliver the picture (no file
channel) or the live stream (video is UDP 9004 only).
"""

from __future__ import annotations

import asyncio

from . import commands
from .ble import BleLink
from .status import CameraStatus, SHOOTING_MODES


class BleSession:
    def __init__(self, emit, loop: asyncio.AbstractEventLoop):
        self.emit = emit
        self.loop = loop
        self.status = CameraStatus()
        self.link: BleLink | None = None
        self.connected = False
        self.address = ""
        self.name = ""
        self._keepalive: asyncio.Task | None = None

    def log(self, message: str) -> None:
        self.emit("log", message)

    # -- lifecycle -------------------------------------------------------

    async def connect(self, address: str, name: str = "Osmo Nano") -> bool:
        self.address = address
        self.name = name
        self.link = BleLink(on_frame=self._on_frame, on_log=self.log)
        try:
            await self.link.connect(address)
        except Exception as exc:  # noqa: BLE001
            self.log(f"BLE connect failed: {exc}")
            return False
        self.connected = True
        self.status.model_name = name
        # A sleeping Nano ACKs commands without executing them. Wake it first:
        # 00/2B [04 00], then 53/10 (answers 01 00 00 00).
        await self._wake()
        # A read-only GET starts the camera's push stream without changing state.
        self.link.send(commands.param_get(0x0038))
        self._keepalive = asyncio.create_task(self._keepalive_loop())
        self.emit("ble_state", "connected")
        self.log(f"BLE-only session with {name} ({address}) - no Wi-Fi needed")
        return True

    async def _wake(self) -> None:
        if not self.link or not self.connected:
            return
        self.link.send(commands.session_wake())
        self.link.send(commands.session_5310())
        await asyncio.sleep(0.9)

    async def disconnect(self) -> None:
        self.connected = False
        if self._keepalive:
            self._keepalive.cancel()
            self._keepalive = None
        if self.link:
            await self.link.disconnect()
            self.link = None
        self.emit("ble_state", "idle")
        self.log("BLE session closed")

    async def _keepalive_loop(self) -> None:
        while self.connected and self.link:
            self.link.send(commands.session_keepalive())
            await asyncio.sleep(1.0)

    def _on_frame(self, frame) -> None:
        if self.status.apply(frame):
            self.emit("status", self.status)
            return
        # Surface mode replies even when the status push lags.
        if frame.cmd_set == 0x02 and frame.cmd_id == 0xE1 and frame.payload:
            self.status.mode_byte = frame.payload[0]
            self.emit("status", self.status)

    # -- actions ---------------------------------------------------------

    async def set_mode(self, mode_byte: int, wake: bool = True) -> bool:
        if not self.link or not self.connected:
            return False
        if wake:
            await self._wake()
        self.link.send(commands.set_shooting_mode(mode_byte))
        self.log(f"BLE mode SET 0x{mode_byte:02X}")
        deadline = self.loop.time() + 2.5
        while self.loop.time() < deadline:
            if self.status.mode_byte == mode_byte:
                self.log(f"mode confirmed: {SHOOTING_MODES.get(mode_byte, mode_byte)}")
                return True
            await asyncio.sleep(0.1)
        return False

    async def take_photo(self) -> bool:
        """Fire a still over BLE. The file stays on the camera."""
        if not self.link or not self.connected:
            self.log("BLE not connected")
            return False
        await self._wake()
        if not self.status.is_photo:
            await self.set_mode(0x05, wake=False)
        self.link.send(commands.shoot_photo())
        reply = await self.link.wait_for(0x0201, timeout=3.0)
        if reply:
            self.log(f"BLE shutter acknowledged ({reply.payload.hex(' ').upper() or '-'})")
            self.emit("ble_shot", None)
            return True
        self.log("BLE shutter: no reply")
        return False
