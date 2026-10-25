"""BLE-only end-to-end against a real Nano: status -> Photo mode -> shutter.

    python tools/selftest_ble.py
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, ".")
from nanotest.ble import scan  # noqa: E402
from nanotest.ble_session import BleSession  # noqa: E402

STATUS_UPDATES = []


def emit(kind, payload):
    if kind == "log":
        print(f"  [log] {payload}")
    elif kind == "status":
        STATUS_UPDATES.append(payload)


async def main() -> int:
    found = await scan(6.0)
    if not found:
        print("no camera found")
        return 1
    device = found[0]
    print(f"camera {device['name']} {device['address']}")

    loop = asyncio.get_running_loop()
    session = BleSession(emit, loop)
    if not await session.connect(device["address"], device["name"] or "Osmo Nano"):
        print("FAIL: connect")
        return 1

    await asyncio.sleep(2.0)
    print(f"status pushes: {len(STATUS_UPDATES)}")
    for label, value in session.status.rows()[:6]:
        print(f"   {label:14} {value}")

    mode_before = session.status.mode_byte
    ok = await session.take_photo()
    print(f"mode before {mode_before}, after {session.status.mode_byte}, shutter ok={ok}")

    # Leave the camera in Video, as found.
    await session.set_mode(0x01)
    await session.disconnect()

    if not ok:
        print("FAIL: BLE shutter not acknowledged")
        return 1
    print("\nOK: BLE-only status + Photo mode + shutter all worked")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
