"""Real-hardware Wi-Fi end-to-end: join the Nano AP, live view, still, download.

Switches this PC's Wi-Fi to the camera for ~60 s. A watchdog process restores the
home network after 150 s no matter what happens here.

    python tools/hw_full.py
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest import wifi  # noqa: E402
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402
from nanotest.session import NanoSession  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_PATH = os.path.join(HERE, "hw_full.log")
FRAME = {"rgb": None, "count": 0}


def log(message: str) -> None:
    line = f"{time.strftime('%H:%M:%S')}  {message}"
    print(line)
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def emit(kind, payload):
    if kind == "frame":
        FRAME["count"] += 1
        FRAME["rgb"] = payload
    elif kind == "log":
        log(f"   {payload}")


def read_creds() -> tuple[str, str]:
    with open(os.path.join(HERE, "hw_creds.txt"), encoding="utf-8") as handle:
        ssid = handle.readline().strip()
        password = handle.readline().rstrip("\n")
    return ssid, password


async def wake_camera() -> None:
    """A sleeping Nano turns its SoftAP off; wake it over BLE first."""
    found = await scan(6.0)
    if not found:
        log("no BLE device to wake (continuing)")
        return
    link = BleLink(on_log=lambda m: None)
    try:
        await link.connect(found[0]["address"])
        link.send(commands.session_wake())
        link.send(commands.session_5310())
        await asyncio.sleep(2.0)
        log("camera woken over BLE (53/10)")
    except Exception as exc:  # noqa: BLE001
        log(f"wake failed: {exc}")
    finally:
        try:
            await link.disconnect()
        except Exception:
            pass


async def run() -> int:
    open(LOG_PATH, "w", encoding="utf-8").close()
    home = wifi.current_ssid()
    ssid, password = read_creds()
    log(f"home wifi: {home!r}; camera: {ssid!r}")

    watchdog = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "tools", "wifi_watchdog.py"), home, "150"],
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    session = None
    try:
        log("joining camera AP")
        await wake_camera()
        ok, ip = wifi.join(ssid, password, timeout=30.0, log=log)
        if not ok:
            log("retry join after 3 s")
            await asyncio.sleep(3.0)
            ok, ip = wifi.join(ssid, password, timeout=25.0, log=log)
        if not ok:
            log("FAIL: could not join the camera AP")
            return 1
        log(f"on camera AP, local IP {ip}")

        loop = asyncio.get_running_loop()
        session = NanoSession(emit, loop)
        log("opening datalink")
        if not await session.connect_direct(
            wifi.CAMERA_HOST, ip, capture_path=os.path.join(HERE, "hw_live.bin")
        ):
            log("FAIL: datalink handshake")
            return 1
        log("handshake ok; starting live view")
        await session.start_live()
        await asyncio.sleep(8.0)
        log(f"live: frames={FRAME['count']} fps={session.measured_fps():.1f} "
            f"packets={session.datalink.video_packets} dropped={session.depacketizer.dropped}")

        if FRAME["rgb"]:
            try:
                from PIL import Image

                Image.frombytes("RGB", (1280, 720), FRAME["rgb"]).save(
                    os.path.join(HERE, "hw_frame.png")
                )
                log("saved hw_frame.png")
            except Exception as exc:  # noqa: BLE001
                log(f"frame save failed: {exc}")

        log("status:")
        for label, value in session.status.rows():
            log(f"   {label:18} {value}")

        log("taking a still")
        path = await session.take_photo(download=True)
        if path and os.path.isfile(path):
            size = os.path.getsize(path)
            with open(path, "rb") as handle:
                magic = handle.read(2)
            log(f"still saved: {path} ({size} bytes, {magic!r})")
        else:
            log("still: not retrieved")

        await session.disconnect()
        return 0 if FRAME["count"] > 20 else 2
    finally:
        if session:
            try:
                await session.disconnect()
            except Exception:
                pass
        log("restoring home wifi")
        restored = wifi.reconnect(home, timeout=30.0, log=log)
        log(f"home wifi restored: {restored} (now {wifi.current_ssid()!r})")
        watchdog.terminate()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run()))
