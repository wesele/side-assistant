"""Diagnose BLE command acceptance: wake, then probe replies one by one.

    python tools/diag_ble.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402

LOG = {"frames": 0, "keys": {}, "e1": [], "shot": [], "mode": None, "wifi": [], "wake": []}


def on_frame(frame):
    LOG["frames"] += 1
    key = f"{frame.cmd_set:02X}/{frame.cmd_id:02X}"
    LOG["keys"][key] = LOG["keys"].get(key, 0) + 1
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x80 and len(frame.payload) > 57:
        LOG["mode"] = frame.payload[57]
    if frame.cmd_set == 0x02 and frame.cmd_id == 0xE1:
        LOG["e1"].append(frame.payload.hex(" ").upper())
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x01:
        LOG["shot"].append(frame.payload.hex(" ").upper())
    if frame.cmd_set == 0x53 and frame.cmd_id == 0x10:
        LOG["wake"].append(frame.payload.hex(" ").upper())
    if frame.cmd_set == 0x07:
        LOG["wifi"].append(f"{frame.cmd_id:02X}:{frame.payload.hex(' ').upper()}")


async def probe(link, label, frame, wait=2.5):
    LOG["keys"] = {}
    LOG["e1"].clear()
    LOG["shot"].clear()
    link.send(frame)
    await asyncio.sleep(wait)
    print(f"{label:28} mode={LOG['mode']} e1={LOG['e1']} shot={LOG['shot']} "
          f"keys={LOG['keys']}")


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera")
        return 1
    link = BleLink(on_frame=on_frame, on_log=lambda m: None)
    await link.connect(found[0]["address"])
    print(f"connected {found[0]['name']}")
    await asyncio.sleep(1.5)
    print(f"initial: mode={LOG['mode']} keys={LOG['keys']}")

    await probe(link, "wake 0x53/0x10", commands.session_5310(), 2.0)
    print(f"   wake replies: {LOG['wake']}")
    await probe(link, "GET selfie flip", commands.param_get(0x0038), 2.0)
    await probe(link, "mode -> Video 0x01", commands.set_shooting_mode(0x01), 2.5)
    await probe(link, "mode -> Photo 0x05", commands.set_shooting_mode(0x05), 2.5)
    await probe(link, "shutter 0x02/0x01", commands.shoot_photo(), 4.0)
    await probe(link, "mode -> Video 0x01", commands.set_shooting_mode(0x01), 2.5)

    print(f"wifi replies: {LOG['wifi']}")
    await link.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
