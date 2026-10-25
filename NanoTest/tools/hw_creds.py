"""After the on-camera approval: verify pairing state and read Wi-Fi credentials.

    python tools/hw_creds.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest import commands  # noqa: E402
from nanotest.ble import BleLink, scan  # noqa: E402
from nanotest.duml import unpack_status_string  # noqa: E402

REPLIES = {}


def on_frame(frame):
    if frame.cmd_set in (0x07, 0x53):
        REPLIES.setdefault(f"{frame.cmd_set:02X}/{frame.cmd_id:02X}", []).append(frame)


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera")
        return 1
    link = BleLink(on_frame=on_frame, on_log=lambda m: print(f"  [ble] {m}"))
    await link.connect(found[0]["address"])
    await asyncio.sleep(1.0)

    link.send(commands.session_wake())
    link.send(commands.session_5310())
    await asyncio.sleep(1.0)

    print("SetPairingPIN")
    link.send(commands.set_pairing_pin())
    await asyncio.sleep(3.0)
    pair = REPLIES.get("07/45", [])
    print(f"  reply: {[f.payload.hex(' ').upper() for f in pair] or 'none'}")
    paired = any(f.payload[:2] == b"\x00\x01" for f in pair)

    ssid = password = ""
    if paired:
        print("GetWifiSsid")
        link.send(commands.get_wifi_ssid())
        await asyncio.sleep(2.0)
        got = REPLIES.get("07/07", [])
        print(f"  raw: {[f.payload.hex(' ').upper() for f in got] or 'none'}")
        if got:
            ssid = unpack_status_string(got[-1].payload)

        print("GetWifiPassword")
        link.send(commands.get_wifi_password())
        await asyncio.sleep(2.0)
        got = REPLIES.get("07/0E", [])
        print(f"  raw: {[f.payload.hex(' ').upper() for f in got] or 'none'}")
        if got:
            password = unpack_status_string(got[-1].payload)

    await link.disconnect()

    if paired:
        print("\nPAIRED")
        print(f"SSID: {ssid!r}")
        print(f"password: {len(password)} chars")
        if ssid and password:
            with open("hw_creds.txt", "w", encoding="utf-8") as handle:
                handle.write(f"{ssid}\n{password}\n")
            print("saved to hw_creds.txt (delete after the test)")
    else:
        print("\nNOT PAIRED YET - approve on the camera screen")
    return 0 if paired else 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
