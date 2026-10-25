"""Measure what actually travels over BLE against a real Nano.

Read-only probe:
  * prints MTU and notification throughput
  * sends a 0x02/0x8E GET (Selfie Flip pid 0x38) - no state change
  * reports whether camera-control frames are answered over GATT

    python tools/ble_probe.py
"""

from __future__ import annotations

import asyncio
import sys
import time

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402

STATS = {"frames": 0, "bytes": 0, "by_key": {}}


def on_frame(frame):
    STATS["frames"] += 1
    STATS["bytes"] += len(frame.payload) + 13
    key = f"{frame.cmd_set:02X}/{frame.cmd_id:02X}"
    STATS["by_key"][key] = STATS["by_key"].get(key, 0) + 1


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera found")
        return 1
    device = found[0]
    print(f"camera {device['name']} {device['address']}")

    link = BleLink(on_frame=on_frame, on_log=lambda m: None)
    await link.connect(device["address"])
    mtu = getattr(link.client, "mtu_size", None)
    print(f"connected; MTU={mtu}")

    # Baseline: how much does the camera push unasked?
    STATS.update(frames=0, bytes=0, by_key={})
    await asyncio.sleep(3.0)
    rate = STATS["bytes"] / 3.0
    print(f"ambient notifications: {STATS['frames']} frames, {STATS['bytes']} bytes "
          f"({rate * 8 / 1000:.0f} kbit/s)")
    print("  keys:", ", ".join(f"{k}x{v}" for k, v in sorted(STATS['by_key'].items())))

    # Read-only camera-control GET over GATT.
    print("sending paramGet(Selfie Flip 0x0038) over FFF5")
    STATS.update(frames=0, bytes=0, by_key={})
    link.send(commands.param_get(0x0038))
    await asyncio.sleep(3.0)
    print(f"  replies/frames after GET: {STATS['frames']} -> {STATS['by_key'] or 'none'}")

    # Control frame that changes only mode, to see whether 0x02/E1 is routed.
    if "--write" in sys.argv:
        print("sending 0x02/E1 [05] (Photo mode) over GATT")
        STATS.update(frames=0, bytes=0, by_key={})
        link.send(commands.set_shooting_mode(0x05))
        await asyncio.sleep(3.0)
        print(f"  frames after mode SET: {STATS['frames']} -> {STATS['by_key'] or 'none'}")
        link.send(commands.set_shooting_mode(0x01))
        await asyncio.sleep(1.0)
    else:
        print("(read-only; pass --write to probe a mode SET)")

    await link.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
