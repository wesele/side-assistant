"""Windows Wi-Fi control via netsh + local-IP probing.

The camera SoftAP has no internet. Windows keeps the association but may warn;
sockets must bind to the 192.168.2.x address, which is what `local_ip_for`
resolves.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import time
import xml.sax.saxutils as sax

CAMERA_HOST = "192.168.2.1"


def _run(args: list[str], timeout: float = 20.0) -> tuple[int, str]:
    try:
        done = subprocess.run(
            args, capture_output=True, timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    out = (done.stdout or b"") + (done.stderr or b"")
    text = out.decode("oem", "replace") if out else ""
    return done.returncode, text


def current_ssid() -> str:
    code, text = _run(["netsh", "wlan", "show", "interfaces"])
    if code != 0:
        return ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("SSID") and "BSSID" not in stripped:
            if ":" in stripped:
                value = stripped.split(":", 1)[1].strip()
                if value:
                    return value
    return ""


def interfaces() -> list[str]:
    code, text = _run(["netsh", "wlan", "show", "interfaces"])
    if code != 0:
        return []
    names = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("name") and ":" in stripped:
            names.append(stripped.split(":", 1)[1].strip())
    return names


def local_ip_for(host: str = CAMERA_HOST, port: int = 9004) -> str:
    """Local address the OS would use to reach `host` (no packets are sent)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(0.5)
        sock.connect((host, port))
        return sock.getsockname()[0]
    except OSError:
        return ""
    finally:
        sock.close()


def profile_xml(ssid: str, password: str) -> str:
    ssid_x = sax.escape(ssid)
    key_x = sax.escape(password)
    return f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>{ssid_x}</name>
  <SSIDConfig><SSID><name>{ssid_x}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>{key_x}</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"""


def join(ssid: str, password: str, timeout: float = 25.0, log=None) -> tuple[bool, str]:
    """Create/refresh a profile and connect. Returns (ok, local_ip)."""
    def say(msg: str) -> None:
        if log:
            log(msg)

    fd, path = tempfile.mkstemp(suffix=".xml", prefix="nanotest-wlan-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(profile_xml(ssid, password))
        code, text = _run(["netsh", "wlan", "add", "profile", f"filename={path}", "user=current"])
        if code != 0:
            say(f"netsh add profile failed: {text.strip()[:300]}")
            return False, ""
        say(f"profile for {ssid} installed")
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

    code, text = _run(["netsh", "wlan", "connect", f"name={ssid}", f"ssid={ssid}"])
    if code != 0:
        say(f"netsh connect failed: {text.strip()[:300]}")
        return False, ""

    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        ip = local_ip_for(CAMERA_HOST)
        if ip.startswith("192.168.2."):
            say(f"associated, local IP {ip}")
            return True, ip
        last = current_ssid()
        time.sleep(0.7)
    say(f"no 192.168.2.x address after {timeout:.0f}s (SSID now '{last}')")
    return False, ""


def disconnect(ssid: str) -> None:
    _run(["netsh", "wlan", "disconnect", f"name={ssid}"])


def reconnect(ssid: str, timeout: float = 25.0, log=None) -> bool:
    """Rejoin a profile that already exists (used to come back from the camera AP)."""
    if not ssid:
        return False
    for attempt in range(3):
        _run(["netsh", "wlan", "connect", f"name={ssid}", f"ssid={ssid}"])
        deadline = time.time() + timeout / 3
        while time.time() < deadline:
            if current_ssid() == ssid:
                if log:
                    log(f"back on {ssid}")
                return True
            time.sleep(0.5)
        if log:
            log(f"reconnect attempt {attempt + 1} did not take")
    return False
