import asyncio
import sys

sys.path.insert(0, ".")
from nanotest.ble import scan  # noqa: E402


async def main():
    found = await scan(5.0)
    print(f"{len(found)} DJI-looking device(s)")
    for item in found:
        print(f"  {item['name']!r} {item['address']} rssi={item['rssi']} model=0x{item['model_id']:04X}")


asyncio.run(main())
