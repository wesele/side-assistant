"""Environment check: python deps, ffmpeg, Bluetooth and Wi-Fi adapters.

    python tools/envcheck.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"[{'OK ' if ok else '-- '}] {label}" + (f"  {detail}" if detail else ""))


def main() -> int:
    print(f"python {sys.version.split()[0]} on {sys.platform}")
    failed = 0

    for module, name in (("bleak", "bleak (BLE)"), ("PIL", "pillow (display)")):
        try:
            __import__(module)
            check(name, True)
        except ImportError:
            check(name, False, "pip install -r requirements.txt")
            failed += 1

    exe = os.environ.get("NANOTEST_FFMPEG") or shutil.which("ffmpeg")
    check("ffmpeg", bool(exe), exe or "install ffmpeg / set NANOTEST_FFMPEG")
    if not exe:
        failed += 1

    if sys.platform == "win32":
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "(Get-PnpDevice -Class Bluetooth -Status OK | Measure-Object).Count"],
                capture_output=True, timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            ).stdout.decode("ascii", "ignore").strip()
            bluetooth = int(out or "0")
            check("Bluetooth devices", bluetooth > 0, f"{bluetooth} present")
            if bluetooth == 0:
                failed += 1
        except Exception as exc:  # noqa: BLE001
            check("Bluetooth devices", False, str(exc))

        try:
            out = subprocess.run(
                ["netsh", "wlan", "show", "interfaces"],
                capture_output=True, timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            text = (out.stdout or b"").decode("oem", "replace") + (
                out.stderr or b""
            ).decode("oem", "replace")
            check("WLAN service", out.returncode == 0 or "SSID" in text)
        except Exception as exc:  # noqa: BLE001
            check("WLAN service", False, str(exc))
            failed += 1

    print()
    print("ready" if failed == 0 else f"{failed} item(s) need attention")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
