"""Independent proof that BLE control executes without app-level pairing.

Does not trust the command ACK alone. Uses two independent observations:
  1. the camera's own 0x02/0x80 mode byte (before / after a mode SET)
  2. free-space bytes from 0x02/0xDC before / after a shutter

    python tools/verify_ble_control.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402
from nanotest.status import CameraStatus  # noqa: E402

STATE = {"status": CameraStatus(), "pair_replies": [], "shutter_replies": []}


def on_frame(frame):
    STATE["status"].apply(frame)
    if frame.cmd_set == 0x07 and frame.cmd_id == 0x45:
        STATE["pair_replies"].append(frame.payload.hex(" ").upper())
    if frame.cmd_set == 0x02 and frame.cmd_id == 0x01:
        STATE["shutter_replies"].append(frame.payload.hex(" ").upper())


def free_mb(status: CameraStatus) -> tuple[int, int]:
    return status.sd_free_mb, status.internal_free_mb


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera found")
        return 1
    link = BleLink(on_frame=on_frame, on_log=lambda m: print(f"  [ble] {m}"))
    await link.connect(found[0]["address"])
    await asyncio.sleep(2.0)
    print(f"connected, app-level pairing state: {STATE['pair_replies'] or 'no reply yet'}")

    # Say hello the same way the app does; this is what returns 00 02 when unpaired.
    link.send(commands.session_wake())
    link.send(commands.set_pairing_pin())
    await asyncio.sleep(3.0)
    print(f"SetPairingPIN reply: {STATE['pair_replies'] or 'none'}  "
          f"(00 02 = camera wants a screen approval)")

    mode0 = STATE["status"].mode_byte
    sd0, int0 = free_mb(STATE["status"])
    print(f"before: mode={mode0} sd_free={sd0}MB internal_free={int0}MB "
          f"battery={STATE['status'].battery_percent}%")

    print("-> 0x02/E1 [05]")
    link.send(commands.set_shooting_mode(0x05))
    await asyncio.sleep(2.0)
    mode1 = STATE["status"].mode_byte
    print(f"   camera-reported mode byte now: {mode1}")

    print("-> 0x02/01 [01] shutter")
    link.send(commands.shoot_photo())
    await asyncio.sleep(5.0)
    sd1, int1 = free_mb(STATE["status"])
    print(f"   shutter replies: {STATE['shutter_replies'] or 'none'}")
    print(f"   after: sd_free={sd1}MB internal_free={int1}MB")

    print("-> restoring Video 0x01")
    link.send(commands.set_shooting_mode(0x01))
    await asyncio.sleep(1.5)
    print(f"   camera-reported mode byte now: {STATE['status'].mode_byte}")

    await link.disconnect()

    print("\n--- verdict ---")
    print(f"mode byte  {mode0} -> {mode1} -> {STATE['status'].mode_byte}")
    print(f"sd free    {sd0} -> {sd1} MB (delta {sd1 - sd0:+d})")
    print(f"int free   {int0} -> {int1} MB (delta {int1 - int0:+d})")
    executed = mode1 == 5 and STATE["status"].mode_byte == 1
    stored = (sd1 - sd0) < 0 or (int1 - int0) < 0
    print(f"control executed: {executed}   storage shrank: {stored}")
    return 0 if executed else 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
