"""Offline analysis of a captured Nano live-view stream.

    python tools/analyze_capture.py hw_capture.bin
"""

from __future__ import annotations

import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


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


def nal_types(au: bytes) -> list[tuple[int, int, int]]:
    """(offset, start_code_len, nal_type) for every Annex-B NAL."""
    out = []
    i = 0
    n = len(au)
    while i < n - 4:
        if au[i] == 0 and au[i + 1] == 0:
            if au[i + 2] == 1:
                out.append((i, 3, au[i + 3] & 0x1F))
                i += 3
                continue
            if au[i + 2] == 0 and au[i + 3] == 1:
                out.append((i, 4, au[i + 4] & 0x1F))
                i += 4
                continue
        i += 1
    return out


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "hw_capture.bin"
    if not os.path.isfile(path):
        print(f"missing {path}")
        return 1
    dats = read_capture(path)
    print(f"datagrams: {len(dats)}  bytes: {os.path.getsize(path)}")

    types = Counter(d[6] for d in dats if len(d) > 6)
    print(f"pktType counts: {dict(types)}")
    sizes = Counter(len(d) for d in dats)
    print(f"datagram sizes (top): {sizes.most_common(5)}")

    # Sequence behaviour
    seqs = [int.from_bytes(d[4:6], "little") for d in dats]
    steps = Counter((seqs[i + 1] - seqs[i]) & 0xFFFF for i in range(len(seqs) - 1))
    print(f"seq steps (top): {steps.most_common(5)}")

    # Rebuild pictures the same way the app does.
    pictures = []
    current = bytearray()
    expected = None
    declared = None
    for d in dats:
        body = d[20:]
        if body[:4] == b"\x00\x00\x01\xff":
            if current:
                pictures.append((declared, bytes(current)))
            count = int.from_bytes(body[4:8], "little")
            declared = count
            current = bytearray(body)
            expected = count + 16
        else:
            current += body
        if expected is not None and len(current) >= expected:
            pictures.append((declared, bytes(current[:expected])))
            current = bytearray()
            expected = None
            declared = None
    if current:
        pictures.append((declared, bytes(current)))

    print(f"\npictures rebuilt: {len(pictures)}")
    for index, (declared_count, blob) in enumerate(pictures[:4]):
        ident = blob[:16]
        au = blob[16:]
        nals = nal_types(au)
        print(f"\npicture {index}: header={' '.join(f'{b:02X}' for b in ident)}")
        print(f"  declared={declared_count} blob={len(blob)} au={len(au)} "
              f"declared+16={None if declared_count is None else declared_count + 16}")
        print(f"  nals={[(off, sc, t) for off, sc, t in nals]}")
        for off, sc, nt in nals[:6]:
            end = len(au)
            for off2, _, _ in nals:
                if off2 > off:
                    end = off2
                    break
            length = end - off - sc
            print(f"    nal {nt:2d} at {off:5d} len {length}")

    ok = 0
    for declared_count, blob in pictures:
        if declared_count is not None and len(blob) == declared_count + 16:
            ok += 1
    print(f"\npictures matching declared size: {ok}/{len(pictures)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
