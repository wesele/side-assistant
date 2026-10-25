"""Headless end-to-end check against the mock camera.

    python tools/selftest.py
"""

from __future__ import annotations

import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest.mock import MockCamera  # noqa: E402
from nanotest.session import NanoSession  # noqa: E402

FRAMES = []
LOGS = []


def emit(kind, payload):
    if kind == "frame":
        FRAMES.append(time.time())
    elif kind == "log":
        LOGS.append(payload)
        print(f"  [log] {payload}")


async def main() -> int:
    loop = asyncio.get_running_loop()
    camera = MockCamera(http_port=18080, log=lambda m: print(f"  [mock] {m}"))
    await camera.start()
    session = NanoSession(emit, loop)

    print("1. connect")
    ok = await session.connect_direct("127.0.0.1", local_ip="127.0.0.1",
                                      media_host="127.0.0.1:18080")
    if not ok:
        print("FAIL: no datalink")
        return 1

    print("2. live view")
    await session.start_live()
    await asyncio.sleep(4.0)
    fps = session.measured_fps()
    print(f"   frames={len(FRAMES)} fps={fps:.1f} packets={session.datalink.video_packets} "
          f"dropped={session.depacketizer.dropped}")
    if len(FRAMES) < 20:
        print("FAIL: live view produced too few frames")
        return 1

    print("3. status")
    for label, value in session.status.rows():
        print(f"   {label:18} {value}")
    if session.status.battery_percent != 87:
        print("FAIL: battery not parsed")
        return 1

    print("4. photo")
    path = await session.take_photo(download=True)
    if not path or not os.path.isfile(path):
        print("FAIL: photo not captured")
        return 1
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        magic = handle.read(2)
    print(f"   saved {path} ({size} bytes, magic {magic!r})")
    if magic != b"\xff\xd8":
        print("FAIL: downloaded file is not a JPEG")
        return 1

    print("5. media list")
    files = await session.list_media()
    print(f"   {len(files)} item(s)")
    if not files:
        print("FAIL: empty media list")
        return 1

    await session.disconnect()
    await camera.stop()
    print("\nOK: datalink, live view, status and stills all worked against the mock")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
