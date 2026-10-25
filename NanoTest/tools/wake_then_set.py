"""Try the documented wake sequence before a mode SET; dump 0x02/0x80 flags.

    python tools/wake_then_set.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402
from nanotest.duml import u32  # noqa: E402

ST = {"e1": [], "shot": [], "mode": None, "flags": None, "rec": None, "play": None}


def on_frame(frame):
    p = frame.payload
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x80 and len(p) >= 58:
        flags = u32(p, 0)
        ST["flags"] = flags
        ST["rec"] = bool(flags & 0x80)
        ST["play"] = bool(flags & 0x40000000)
        ST["mode"] = p[57]
    if frame.cmd_set == 0x02 and frame.cmd_id == 0xE1:
        ST["e1"].append(p.hex(" ").upper())
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x01:
        ST["shot"].append(p.hex(" ").upper())


async def main() -> int:
    found = await scan(6.0)
    if not found:
        return 1
    link = BleLink(on_frame=on_frame, on_log=lambda m: None)
    await link.connect(found[0]["address"])
    await asyncio.sleep(1.5)
    print(f"state: mode={ST['mode']} rec={ST['rec']} playback={ST['play']} flags=0x{ST['flags'] or 0:08X}")

    print("wake: 0x00/0x2B [04 00]")
    link.send(commands.session_wake())
    await asyncio.sleep(1.0)
    print("wake AP: 0x53/0x10")
    link.send(commands.session_5310())
    await asyncio.sleep(2.0)
    print(f"after wake: mode={ST['mode']} playback={ST['play']}")

    ST["e1"].clear()
    print("0x02/E1 [05]")
    link.send(commands.set_shooting_mode(0x05))
    await asyncio.sleep(3.0)
    print(f"  e1={ST['e1']} mode={ST['mode']}")

    ST["shot"].clear()
    print("0x02/01 [01]")
    link.send(commands.shoot_photo())
    await asyncio.sleep(3.0)
    print(f"  shot={ST['shot']} mode={ST['mode']}")

    print("restore 0x02/E1 [01]")
    link.send(commands.set_shooting_mode(0x01))
    await asyncio.sleep(2.0)
    print(f"  mode={ST['mode']}")

    await link.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
