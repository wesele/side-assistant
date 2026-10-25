import asyncio
import sys
import time

sys.path.insert(0, ".")
from nanotest.mock import MockCamera  # noqa: E402
from nanotest.session import NanoSession  # noqa: E402

frames = []


def emit(kind, payload):
    if kind == "frame":
        frames.append(time.time())


async def main():
    loop = asyncio.get_running_loop()
    cam = MockCamera(http_port=18096, log=print)
    await cam.start()
    s = NanoSession(emit, loop)
    await s.connect_direct("127.0.0.1", local_ip="127.0.0.1", media_host="127.0.0.1:18096")
    await s.start_live()
    for i in range(8):
        await asyncio.sleep(1)
        errors = s.decoder.decode_errors if s.decoder else -1
        print(f"t={i+1}s frames={len(frames)} pkts={s.datalink.video_packets} "
              f"dropped={s.depacketizer.dropped} decode_err={errors} fps={s.measured_fps():.1f}")
    print("intervals", [round(frames[i + 1] - frames[i], 3) for i in range(min(12, len(frames) - 1))])
    await s.disconnect()
    await cam.stop()


asyncio.run(main())
