"""Media list decoding (`0x00/0x26` / `0x00/0x27`) and SoftAP HTTP fetch.

Ported (simplified, still byte-faithful) from OpenCine `MediaManifest+DJIWire.swift`
and `MediaManifest.swift`, Apache-2.0.
"""

from __future__ import annotations

import os
import urllib.parse
import urllib.request
from dataclasses import dataclass

VIDEO_EXT = {"MP4", "MOV", "OSV", "INSV", "LRF", "LRV", "XRF"}
PHOTO_EXT = {"JPG", "JPEG", "DNG", "HEIC", "TIF", "TIFF", "PANO"}


@dataclass
class MediaFile:
    path: str
    handle: int = 0
    size_bytes: int = 0
    kind: str = "photo"  # photo | video
    storage: int = 0
    thumb: str = ""
    resolution: str = ""

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1]

    @property
    def is_photo(self) -> bool:
        return self.kind == "photo"


class MediaChunkAssembler:
    """`0x00/0x27` chunks: `[10B sub][chunk]`, subtype 04 start / 01 data / 03 end."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.data: dict[int, bytearray] = {}
        self.started: set[int] = set()
        self.ended: set[int] = set()

    def ingest(self, frame) -> bool:
        if frame.cmd_set != 0x00 or frame.cmd_id != 0x27:
            return False
        p = frame.payload
        if len(p) < 10 or p[0] != 0x4A:
            return False
        subtype = p[1]
        counter = p[4]
        if subtype == 0x04:
            self.started.add(counter)
            self.data.setdefault(counter, bytearray())
            return True
        if subtype == 0x03:
            self.ended.add(counter)
            return True
        if subtype == 0x01 and len(p) > 10:
            self.data.setdefault(counter, bytearray()).extend(p[10:])
            return True
        return False

    def closed(self, counter: int) -> bool:
        return counter in self.ended or (
            counter in self.started and not self.data.get(counter)
        )


def _read_path(data: bytes, i: int, sub: int, prefix: str):
    if i + 6 > len(data) or data[i] != 0x1A:
        return None
    if data[i + 2] != 0 or data[i + 3] != 0 or data[i + 4] != 0:
        return None
    if data[i + 5] != sub:
        return None
    slen = data[i + 1] - 6
    if slen < len(prefix) or i + 6 + slen > len(data):
        return None
    raw = data[i + 6 : i + 6 + slen]
    if not all(0x20 <= b <= 0x7E for b in raw):
        return None
    value = raw.decode("latin-1")
    if not value.startswith(prefix):
        return None
    return value, i + 6 + slen


def _u32(data: bytes, off: int) -> int:
    return data[off] | (data[off + 1] << 8) | (data[off + 2] << 16) | (data[off + 3] << 24)


def decode_manifest(data: bytes, storage: int = 0) -> list[MediaFile]:
    """CompositePack TLV walk: `1A len 00 00 00 sub <path>` anchors each record."""
    anchors = []
    i = 0
    while i < len(data):
        found = _read_path(data, i, 1, "DCIM/")
        if found:
            anchors.append((i, found[1], found[0]))
            i = found[1]
        else:
            i += 1
    if not anchors:
        return []

    out: list[MediaFile] = []
    seen: set[str] = set()
    for k, (pos, end, directory) in enumerate(anchors):
        if directory in seen:
            continue
        seen.add(directory)
        lo = anchors[k - 1][1] if k > 0 else 0
        hi = anchors[k + 1][0] if k + 1 < len(anchors) else len(data)
        base = directory.rsplit("/", 1)[-1]
        window = data[lo:hi]

        thumb = ""
        for t in range(len(window)):
            found = _read_path(data, lo + t, 2, "MISC/")
            if found and found[0].endswith(base):
                thumb = found[0]
                break

        ext = ""
        for n in range(len(window) - 2):
            if window[n] == 0x0D:
                length = window[n + 1]
                if length > len(base) and n + 2 + length <= len(window):
                    raw = window[n + 2 : n + 2 + length]
                    try:
                        value = raw.decode("latin-1")
                    except Exception:
                        continue
                    if value.startswith(base + "."):
                        candidate = value[len(base) + 1 :].upper()
                        if candidate in VIDEO_EXT or candidate in PHOTO_EXT:
                            ext = candidate
                            break

        handle = 0
        head = -1
        for m in range(len(window) - 4):
            if (
                window[m] in (0x03, 0x00)
                and window[m + 1] in (0xFF, 0xFE)
                and window[m + 2] == 0x19
                and window[m + 3] == 0x06
                and m >= 8
            ):
                head = m - 8
                break
        if head >= 0 and lo + head + 4 <= len(data):
            handle = _u32(data, lo + head)
        elif pos >= 17 and data[pos - 7] == 0x19 and data[pos - 6] == 0x06:
            handle = _u32(data, pos - 17)

        is_video = ext in VIDEO_EXT
        size = 0
        resolution = ""
        if is_video and head >= 0 and head >= 4:
            size = _u32(data, lo + head - 4)
        if not is_video:
            for q in range(len(window) - 3):
                if window[q] in (0xFF, 0xFE) and window[q + 1] == 0x19 and window[q + 2] == 0x06:
                    mk = lo + q + 1
                    if mk >= 14:
                        size = _u32(data, mk - 14)
                    if mk + 66 <= len(data):
                        w = _u32(data, mk + 58)
                        h = _u32(data, mk + 62)
                        if 1 <= w <= 60000 and 1 <= h <= 60000:
                            resolution = f"{w}x{h}"
                    break

        path = directory if not ext else f"{directory}.{ext}"
        out.append(
            MediaFile(
                path=path,
                handle=handle,
                size_bytes=size,
                kind="video" if is_video else "photo",
                storage=storage,
                thumb=thumb,
                resolution=resolution,
            )
        )
    return out


def media_url(host: str, storage: int, path: str) -> str:
    query = urllib.parse.urlencode({"storage": storage, "path": path}, safe="/")
    return f"http://{host}/v2?{query}"


def fetch_media(
    host: str,
    file: MediaFile,
    dest_dir: str,
    progress=None,
    timeout: float = 60.0,
) -> str:
    os.makedirs(dest_dir, exist_ok=True)
    url = media_url(host, file.storage, file.path)
    dest = os.path.join(dest_dir, file.name)
    request = urllib.request.Request(url, headers={"Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        total = int(response.headers.get("Content-Length") or file.size_bytes or 0)
        done = 0
        with open(dest, "wb") as handle:
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                done += len(chunk)
                if progress:
                    progress(done, total)
    return dest
