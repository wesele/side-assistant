"""Replay a capture through the app's Depacketizer and decode it with ffmpeg.

    python tools/replay_capture.py hw_capture.bin
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest.video import Depacketizer, find_ffmpeg  # noqa: E402


def read_capture(path: str) -> list[bytes]:
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


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "hw_capture.bin"
    dats = read_capture(path)
    dep = Depacketizer()
    aus = []
    for d in dats:
        au = dep.feed(d)
        if au:
            aus.append(au)
    print(f"datagrams {len(dats)} -> AUs {len(aus)}  dropped={dep.dropped}")
    if aus:
        print(f"first AU {len(aus[0])} B sha={hashlib.sha256(aus[0]).hexdigest()[:16]}")
        print(f"second AU {len(aus[1])} B")

    out_path = os.path.join(os.path.dirname(path), "replay.h264")
    with open(out_path, "wb") as handle:
        for au in aus:
            handle.write(au)
    print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes)")

    exe = find_ffmpeg()
    if exe:
        result = subprocess.run(
            [exe, "-hide_banner", "-f", "h264", "-i", out_path, "-f", "null", "-"],
            capture_output=True, text=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        tail = [line for line in result.stderr.splitlines() if line.strip()][-6:]
        print("ffmpeg:", "\n        ".join(tail))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
