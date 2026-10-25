"""Try the real BLE pairing path against a nearby Nano.

    python tools/test_ble.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402

REPLIES = []


def on_frame(frame):
    REPLIES.append(frame)
    print(f"  <- {frame.cmd_set:02X}/{frame.cmd_id:02X} flags={frame.flags:02X} "
          f"seq={frame.seq} payload={frame.payload.hex(' ').upper()[:120]}")


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no DJI camera found")
        return 1
    device = found[0]
    print(f"camera: {device['name']} {device['address']} rssi={device['rssi']}")

    link = BleLink(on_frame=on_frame, on_log=lambda m: print(f"  [ble] {m}"))
    await link.connect(device["address"])
    print("gatt connected; services:")
    for service in link.client.services:
        print(f"  service {service.uuid}")
        for char in service.characteristics:
            print(f"    char {char.uuid} props={','.join(char.properties)}")

    print("sending wake + SetPairingPIN('osmo')")
    ok = await link.pair(timeout=25.0)
    print(f"pair() -> {ok}")
    if not ok:
        for reply in REPLIES:
            if reply.cmd_set == 0x07 and reply.cmd_id == 0x45:
                print(f"  pairing reply: {reply.payload.hex(' ').upper()}")
        await link.disconnect()
        return 2

    print("requesting Wi-Fi credentials")
    ssid, password = await link.wifi_credentials(timeout=6.0)
    print(f"SSID: {ssid!r}  password length: {len(password)}")
    await link.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
