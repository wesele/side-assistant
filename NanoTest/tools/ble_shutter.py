"""Can BLE alone fire the shutter? Real Nano, minimal state change.

  * reads current mode from 0x02/0x80 @57
  * sends 0x02/E1 [05]  (Photo mode)
  * sends 0x02/0x01 [01] (shutter)
  * restores Video mode 0x01

    python tools/ble_shutter.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402

SEEN = {"mode": None, "e1": [], "shutter": [], "counts": {}}


def on_frame(frame):
    key = f"{frame.cmd_set:02X}/{frame.cmd_id:02X}"
    SEEN["counts"][key] = SEEN["counts"].get(key, 0) + 1
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x80 and len(frame.payload) > 57:
        SEEN["mode"] = frame.payload[57]
    if frame.cmd_set == 0x02 and frame.cmd_id == 0xE1:
        SEEN["e1"].append(frame.payload.hex(" ").upper())
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x01:
        SEEN["shutter"].append(frame.payload.hex(" ").upper())


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera found")
        return 1
    link = BleLink(on_frame=on_frame, on_log=lambda m: None)
    await link.connect(found[0]["address"])
    print(f"connected to {found[0]['name']}")

    # A read-only GET wakes the push stream without changing anything.
    link.send(commands.param_get(0x0038))
    await asyncio.sleep(2.0)
    print(f"mode before: {SEEN['mode']} (0x{SEEN['mode']:02X})" if SEEN["mode"] is not None else "mode before: unknown")

    print("-> 0x02/E1 [05] Photo mode")
    link.send(commands.set_shooting_mode(0x05))
    await asyncio.sleep(2.0)
    print(f"   E1 replies: {SEEN['e1'] or 'none'}")
    print(f"   mode now: {SEEN['mode']} (0x{SEEN['mode']:02X})" if SEEN["mode"] is not None else "   mode now: unknown")

    print("-> 0x02/01 [01] shutter")
    link.send(commands.shoot_photo())
    await asyncio.sleep(4.0)
    print(f"   shutter replies: {SEEN['shutter'] or 'none'}")
    print(f"   mode after: {SEEN['mode']}")

    print("-> restoring 0x02/E1 [01] Video mode")
    link.send(commands.set_shooting_mode(0x01))
    await asyncio.sleep(1.0)

    print("frame counts:", ", ".join(f"{k}x{v}" for k, v in sorted(SEEN["counts"].items())))
    await link.disconnect()

    if SEEN["shutter"]:
        print("\nRESULT: BLE shutter was acknowledged -> BLE-only remote capture is plausible")
    else:
        print("\nRESULT: no shutter reply over BLE")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
