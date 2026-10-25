"""Capture ~8 s of real Nano live-view datagrams for offline analysis.

Switches the PC to the camera AP, captures pktType 0x02 to hw_capture.bin,
then restores the home network. A watchdog restores it after 150 s regardless.

    python tools/hw_capture.py
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest import wifi  # noqa: E402
from nanotest.session import NanoSession  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURE = os.path.join(HERE, "hw_capture.bin")


def log(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')}  {message}")


def emit(kind, payload):
    if kind == "log":
        log(f"   {payload}")


def read_creds() -> tuple[str, str]:
    with open(os.path.join(HERE, "hw_creds.txt"), encoding="utf-8") as handle:
        return handle.readline().strip(), handle.readline().rstrip("\n")


async def run() -> int:
    home = wifi.current_ssid()
    ssid, password = read_creds()
    log(f"home {home!r} -> camera {ssid!r}")
    watchdog = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "tools", "wifi_watchdog.py"), home, "150"],
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    session = None
    try:
        ok, ip = wifi.join(ssid, password, timeout=30.0, log=log)
        if not ok:
            log("FAIL join")
            return 1
        session = NanoSession(emit, asyncio.get_running_loop())
        if not await session.connect_direct(wifi.CAMERA_HOST, ip, capture_path=CAPTURE):
            log("FAIL handshake")
            return 1
        await session.start_live()
        await asyncio.sleep(8.0)
        log(f"captured {session.datalink.video_packets} video datagrams")
        return 0
    finally:
        if session:
            await session.disconnect()
        restored = wifi.reconnect(home, timeout=30.0, log=log)
        log(f"home restored: {restored} ({wifi.current_ssid()!r})")
        watchdog.terminate()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run()))
