"""Feed a captured stream through the real decoder, with and without sanitizing.

    python tools/test_decode.py hw_capture.bin
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest import video  # noqa: E402
from nanotest.video import Depacketizer, H264Decoder  # noqa: E402


def read_capture(path):
    out = []
    with open(path, "rb") as handle:
        while True:
            head = handle.read(4)
            if len(head) < 4:
                break
            size = int.from_bytes(head, "little")
            data = handle.read(size)
            if len(data) < size:
                break
            out.append(data)
    return out


def run(label: str, aus, sanitize: bool) -> int:
    frames = []
    errors = []
    original = video.sanitize_au
    if not sanitize:
        video.sanitize_au = lambda au: au
    try:
        decoder = H264Decoder(on_frame=lambda rgb: frames.append(time.time()),
                              on_log=lambda m: errors.append(m))
        if not decoder.start():
            print("ffmpeg missing")
            return 0
        for au in aus:
            decoder.feed(au)
            time.sleep(0.02)
        time.sleep(1.5)
        decoder.stop()
    finally:
        video.sanitize_au = original
    print(f"{label:14} frames={len(frames):4d} errors={len(errors)}")
    return len(frames)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "hw_capture.bin"
    dats = read_capture(path)
    dep = Depacketizer()
    aus = [au for au in (dep.feed(d) for d in dats) if au]
    print(f"{len(aus)} access units from {len(dats)} datagrams")
    plain = run("raw", aus, sanitize=False)
    clean = run("sanitized", aus, sanitize=True)
    print(f"\nraw {plain} -> sanitized {clean}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
