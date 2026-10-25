"""Watchdog: if the machine is still on the camera AP, go back to the home Wi-Fi.

    python tools/wifi_watchdog.py "<home ssid>" 150
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from nanotest import wifi  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        return 1
    home = sys.argv[1]
    delay = float(sys.argv[2]) if len(sys.argv) > 2 else 150.0
    time.sleep(delay)
    current = wifi.current_ssid()
    if current != home:
        wifi.reconnect(home, timeout=25.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
