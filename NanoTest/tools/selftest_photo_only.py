"""Prove the still-only path: connect, never enable live view, shoot, fetch.

    python tools/selftest_photo_only.py
"""

from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest.mock import MockCamera  # noqa: E402
from nanotest.session import NanoSession  # noqa: E402

LOGS = []


def emit(kind, payload):
    if kind == "log":
        LOGS.append(payload)
        print(f"  [log] {payload}")


async def main() -> int:
    loop = asyncio.get_running_loop()
    camera = MockCamera(http_port=18097, log=lambda m: print(f"  [mock] {m}"))
    await camera.start()
    session = NanoSession(emit, loop)

    ok = await session.connect_direct("127.0.0.1", local_ip="127.0.0.1",
                                      media_host="127.0.0.1:18097")
    if not ok:
        print("FAIL: connect")
        return 1

    # Deliberately no start_live(): the camera never gets 0x09/0xA8.
    await asyncio.sleep(1.0)
    print(f"live enabled? {session.live}   video packets: {session.datalink.video_packets}")
    if session.live or session.datalink.video_packets:
        print("FAIL: live view started unexpectedly")
        return 1

    path = await session.take_photo(download=True)
    if not path or not os.path.isfile(path):
        print("FAIL: no still")
        return 1
    with open(path, "rb") as handle:
        magic = handle.read(2)
    print(f"still: {path} ({os.path.getsize(path)} bytes, {magic!r})")
    print(f"video packets after the whole run: {session.datalink.video_packets} "
          f"(camera never sent a picture)")
    if session.datalink.video_packets:
        print("FAIL: video arrived although live view was never enabled")
        return 1
    if magic != b"\xff\xd8":
        print("FAIL: not a JPEG")
        return 1

    await session.disconnect()
    await camera.stop()
    print("\nOK: still capture works with the live stream never enabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
