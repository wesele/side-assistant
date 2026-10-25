"""BLE pairing link for DJI Osmo cameras (bleak / WinRT).

The camera exposes service FFF0:
  * FFF4 - notify + "arm pairing" (write 01 00 with response)
  * FFF5 - command writes (DUML frames, write-without-response, paced ~120 ms)

Ported from OpenCine `DjiAppleBluetoothLink.swift` + `DjiAppleConnectionRun.swift`.
"""

from __future__ import annotations

import asyncio
import time

from . import commands
from .duml import Frame, crc8, crc16, encode, scan_frames, unpack_status_string

SERVICE = "0000fff0-0000-1000-8000-00805f9b34fb"
CHAR_NOTIFY = "0000fff4-0000-1000-8000-00805f9b34fb"
CHAR_WRITE = "0000fff5-0000-1000-8000-00805f9b34fb"
DJI_COMPANY_IDS = {0x08AA, 0xF7AA, 0xE5C0}


class Assembler:
    """Notification boundaries are not DUML boundaries."""

    def __init__(self) -> None:
        self.pending = bytearray()

    def append(self, data: bytes) -> list[Frame]:
        if len(data) > 4096:
            self.pending.clear()
            return []
        if len(self.pending) + len(data) > 4096:
            self.pending.clear()
        self.pending += data
        out: list[Frame] = []
        while len(self.pending) >= 4:
            if self.pending[0] != 0x55 or (self.pending[2] >> 2) != 1 or crc8(
                bytes(self.pending[:3])
            ) != self.pending[3]:
                del self.pending[0]
                continue
            length = self.pending[1] | ((self.pending[2] & 3) << 8)
            if length < 13:
                del self.pending[0]
                continue
            if len(self.pending) < length:
                break
            checksum = self.pending[length - 2] | (self.pending[length - 1] << 8)
            if crc16(bytes(self.pending[: length - 2])) == checksum:
                frames = scan_frames(bytes(self.pending[:length]))
                if frames:
                    out.append(frames[0])
                    del self.pending[:length]
                    continue
            del self.pending[0]
        return out


async def scan(timeout: float = 8.0):
    """Discover DJI cameras. Returns dicts for the UI list."""
    from bleak import BleakScanner

    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    found = []
    for address, (device, adv) in devices.items():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        company = set((adv.manufacturer_data or {}).keys())
        name = adv.local_name or device.name or ""
        lowered = name.lower()
        looks_dji = any(tag in lowered for tag in ("osmo", "nano", "dji", "pocket", "action"))
        is_dji = SERVICE in uuids or bool(company & DJI_COMPANY_IDS) or looks_dji
        if not is_dji:
            continue
        found.append(
            {
                "address": address,
                "name": name,
                "rssi": adv.rssi,
                "model_id": _model_id(adv.manufacturer_data or {}),
            }
        )
    found.sort(key=lambda d: -(d["rssi"] or -999))
    return found


def _model_id(manufacturer: dict) -> int:
    for cid, payload in manufacturer.items():
        if cid in DJI_COMPANY_IDS and len(payload) >= 2:
            return payload[0] | (payload[1] << 8)
    return -1


class BleLink:
    def __init__(self, on_frame=None, on_log=None, pace: float = 0.12):
        self.on_frame = on_frame
        self.on_log = on_log
        self.pace = pace
        self.client = None
        self.write_char = None
        self.notify_char = None
        self.assembler = Assembler()
        self._queue: asyncio.Queue[Frame] = asyncio.Queue()
        self._pump_task: asyncio.Task | None = None
        self._waiters: dict[int, list[asyncio.Future]] = {}
        self._auto_approve = True
        self.paired = False
        self.address = ""

    def _log(self, message: str) -> None:
        if self.on_log:
            self.on_log(message)

    async def connect(self, address: str, timeout: float = 20.0) -> None:
        from bleak import BleakClient

        self.address = address
        self.client = BleakClient(address, timeout=timeout)
        await self.client.connect()
        self._log(f"BLE connected to {address}")
        services = self.client.services
        for service in services:
            if service.uuid.lower() != SERVICE:
                continue
            for char in service.characteristics:
                uuid = char.uuid.lower()
                if uuid == CHAR_NOTIFY:
                    self.notify_char = char
                elif uuid == CHAR_WRITE:
                    self.write_char = char
        if not self.write_char:
            raise RuntimeError("cameras FFF5 characteristic not found")

        await self.client.start_notify(
            self.write_char.uuid, self._on_notify
        )
        if self.notify_char:
            await self.client.start_notify(self.notify_char.uuid, self._on_notify)
            # Arm pairing: 01 00 written with response to FFF4.
            try:
                await self.client.write_gatt_char(
                    self.notify_char.uuid, b"\x01\x00", response=True
                )
                self._log("BLE armed pairing (FFF4 <- 01 00)")
            except Exception as exc:  # noqa: BLE001
                self._log(f"arm-pairing write failed: {exc}")

        self._pump_task = asyncio.create_task(self._pump())

    async def disconnect(self) -> None:
        if self._pump_task:
            self._pump_task.cancel()
            self._pump_task = None
        if self.client and self.client.is_connected:
            try:
                await self.client.disconnect()
            except Exception:
                pass
        self.client = None
        self._log("BLE disconnected")

    # -- io --------------------------------------------------------------

    def _on_notify(self, _char, data: bytearray) -> None:
        for frame in self.assembler.append(bytes(data)):
            self._dispatch(frame)

    def _dispatch(self, frame: Frame) -> None:
        if frame.cmd_set == 0x07 and frame.cmd_id == 0x46 and frame.flags == 0x40:
            if self._auto_approve:
                self._log("camera asks for pairing approval - approving")
                self.send(commands.pair_approval_ack(frame.seq))
        waiters = self._waiters.pop(frame.key, [])
        for fut in waiters:
            if not fut.done():
                fut.set_result(frame)
        if self.on_frame:
            self.on_frame(frame)

    def send(self, frame: Frame) -> None:
        self._queue.put_nowait(frame)

    async def _pump(self) -> None:
        while True:
            frame = await self._queue.get()
            if not self.client or not self.client.is_connected or not self.write_char:
                continue
            try:
                await self.client.write_gatt_char(
                    self.write_char.uuid, encode(frame), response=False
                )
            except Exception as exc:  # noqa: BLE001
                self._log(f"BLE write failed: {exc}")
            await asyncio.sleep(self.pace)

    async def wait_for(self, key: int, timeout: float = 4.0, predicate=None):
        fut = asyncio.get_running_loop().create_future()
        self._waiters.setdefault(key, []).append(fut)
        try:
            frame = await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            return None
        if predicate and not predicate(frame):
            return None
        return frame

    # -- pairing ---------------------------------------------------------

    async def pair(self, timeout: float = 30.0) -> bool:
        self.send(commands.session_wake())
        self.send(commands.set_pairing_pin())
        deadline = time.time() + timeout
        last_pin = time.time()
        while time.time() < deadline:
            frame = await self.wait_for(0x0745, timeout=min(4.0, max(0.5, deadline - time.time())))
            if frame:
                p = frame.payload
                if len(p) >= 2 and p[0] == 0x00:
                    if p[1] == 0x01:
                        self.paired = True
                        self._log("pairing: approved (00 01)")
                        return True
                    if p[1] == 0x02:
                        self._log("pairing: waiting for approval on the camera screen")
                    if p[1] == 0x06:
                        self._log("pairing: camera deferred (00 06), retrying")
                        self.send(commands.set_pairing_pin())
                        last_pin = time.time()
            # Mimo keeps asking while the operator reaches for the camera.
            if time.time() - last_pin > 5.0:
                self._log("pairing: re-sending SetPairingPIN")
                self.send(commands.set_pairing_pin())
                last_pin = time.time()
        return False

    async def wifi_credentials(self, timeout: float = 6.0) -> tuple[str, str]:
        self.send(commands.session_5310())
        await asyncio.sleep(0.6)
        ssid = ""
        password = ""
        self.send(commands.get_wifi_ssid())
        frame = await self.wait_for(0x0707, timeout=timeout)
        if frame:
            ssid = unpack_status_string(frame.payload)
        self.send(commands.get_wifi_password())
        frame = await self.wait_for(0x070E, timeout=timeout)
        if frame:
            password = unpack_status_string(frame.payload)
        return ssid, password
