"""Test workflow:
1. Connect Osmo Nano over BLE (and keep it connected)
2. Wake camera and SoftAP
3. Connect WLAN 2 to Nano SoftAP (192.168.2.1)
4. Establish Wi-Fi DUML Datalink
5. Send photo shutter command
6. Retrieve/download the photo via HTTP
7. Disconnect Wi-Fi while retaining the BLE connection
8. Print a timing log of each step
"""

from __future__ import annotations

import asyncio
import os
import re
import subprocess
import sys
import tempfile
import time

# Ensure nanotest is in path
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from nanotest import commands, media, wifi
from nanotest.ble import BleLink, scan
from nanotest.datalink import Datalink
from nanotest.session import CAPTURE_DIR, NanoSession

# Reconfigure stdout to utf-8
if sys.stdout.encoding.lower() != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def _run_cmd(args: list[str], timeout: float = 20.0) -> tuple[int, str]:
    try:
        done = subprocess.run(
            args,
            capture_output=True,
            timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    out = (done.stdout or b"") + (done.stderr or b"")
    try:
        text = out.decode("utf-8")
    except UnicodeDecodeError:
        text = out.decode("gbk", "replace") if out else ""
    return done.returncode, text


def get_wlan2_ip() -> str:
    code, text = _run_cmd(["netsh", "interface", "ipv4", "show", "addresses", "WLAN 2"])
    if code != 0:
        return ""
    matches = re.findall(r"\b(192\.168\.2\.\d{1,3})\b", text)
    return matches[0] if matches else ""


def join_wlan2(ssid: str, password: str, timeout: float = 25.0, log=print) -> tuple[bool, str]:
    xml_content = wifi.profile_xml(ssid, password)
    fd, path = tempfile.mkstemp(suffix=".xml", prefix="nano-wlan2-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as h:
            h.write(xml_content)
        code, text = _run_cmd(
            ["netsh", "wlan", "add", "profile", f"filename={path}", "interface=WLAN 2", "user=current"]
        )
        if code != 0:
            log(f"  [WLAN2] add profile failed: {text.strip()}")
            return False, ""
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

    code, text = _run_cmd(
        ["netsh", "wlan", "connect", f"name={ssid}", f"ssid={ssid}", "interface=WLAN 2"]
    )
    if code != 0:
        log(f"  [WLAN2] connect failed: {text.strip()}")
        return False, ""

    deadline = time.time() + timeout
    while time.time() < deadline:
        ip = get_wlan2_ip()
        if ip:
            return True, ip
        time.sleep(0.5)
    return False, ""


def disconnect_wlan2() -> bool:
    code, _ = _run_cmd(["netsh", "wlan", "disconnect", "interface=WLAN 2"])
    return code == 0


class TimingLogger:
    def __init__(self):
        self.records: list[dict] = []
        self._cur_name = None
        self._t0 = 0.0

    def start(self, name: str):
        if self._cur_name:
            self.stop("AUTO_FINISH")
        self._cur_name = name
        self._t0 = time.perf_counter()
        print(f"\n>>> [{time.strftime('%H:%M:%S')}] 开始: {name}")

    def stop(self, status: str = "成功", details: str = ""):
        if not self._cur_name:
            return
        dt = time.perf_counter() - self._t0
        self.records.append(
            {
                "name": self._cur_name,
                "duration": dt,
                "status": status,
                "details": details,
            }
        )
        print(f"<<< [{time.strftime('%H:%M:%S')}] 完成: {self._cur_name} | 耗时: {dt:.3f}s | 状态: {status} {details}")
        self._cur_name = None

    def print_summary(self):
        print("\n" + "=" * 85)
        print("                  DJI Osmo Nano WLAN 2 自动化测试时间日志")
        print("=" * 85)
        total_time = sum(r["duration"] for r in self.records)
        header = f"{'步骤':<30} | {'耗时(秒)':<10} | {'状态':<6} | {'详细信息'}"
        print(header)
        print("-" * 85)
        for r in self.records:
            print(f"{r['name']:<30} | {r['duration']:>8.3f}s | {r['status']:<6} | {r['details']}")
        print("-" * 85)
        print(f"{'总计耗时':<30} | {total_time:>8.3f}s |")
        print("=" * 85 + "\n")


async def shoot_and_download(
    session: NanoSession,
    timer: TimingLogger,
    step_label: str,
    before_paths: set[str],
) -> tuple[str, set[str]]:
    """Shoot a photo, wait for reply, find it in the manifest, download via HTTP, and verify."""
    timer.start(f"{step_label} - 触发快门")
    session.datalink.send(commands.shoot_photo())
    ack = await session._wait(0x0201, timeout=3.0)
    ack_str = ack.payload.hex(" ").upper() if ack else "无回执"
    timer.stop("成功" if ack else "警告", f"快门回执: {ack_str}")

    timer.start(f"{step_label} - 取回照片")
    new_photo = None
    deadline = time.time() + 8.0
    while time.time() < deadline:
        await asyncio.sleep(0.5)
        files = await session.list_media()
        photos = [f for f in files if f.is_photo]
        fresh = [f for f in photos if f.path not in before_paths]
        if fresh:
            new_photo = fresh[-1]
            break
        elif photos and not before_paths:
            new_photo = photos[-1]
            break

    if not new_photo:
        timer.stop("失败", "清单中未见新文件")
        raise RuntimeError(f"{step_label} 取照片失败: 清单中未见新文件")

    print(f"  [{step_label}] 发现新文件: {new_photo.path} ({new_photo.size_bytes} 字节)")
    dest_path = await session.download(new_photo)
    file_size = os.path.getsize(dest_path) if os.path.isfile(dest_path) else 0

    is_valid_jpeg = False
    if os.path.isfile(dest_path) and file_size > 0:
        with open(dest_path, "rb") as fh:
            is_valid_jpeg = fh.read(3) == b"\xFF\xD8\xFF"

    timer.stop(
        "成功",
        f"保存至 {os.path.basename(dest_path)} ({file_size / 1024:.1f} KB, JPEG有效: {is_valid_jpeg})",
    )
    new_before = before_paths | {new_photo.path}
    return dest_path, new_before


async def connect_wifi_and_datalink(
    ssid: str,
    password: str,
    timer: TimingLogger,
    step_label: str,
    ble_link: BleLink | None = None,
) -> tuple[NanoSession, set[str]]:
    """Connect WLAN 2 to camera SoftAP, open DUML datalink, ensure photo mode, and get baseline manifest."""
    if ble_link:
        ble_link.send(commands.session_5310())
        await asyncio.sleep(0.5)

    timer.start(f"{step_label} - WLAN 2 连接 SoftAP")
    connected, wlan2_ip = join_wlan2(ssid, password, timeout=25.0, log=print)
    if not connected:
        timer.stop("失败", f"WLAN 2 无法加入 {ssid}")
        raise RuntimeError(f"WLAN 2 无法加入 {ssid}")
    timer.stop("成功", f"分配 IP: {wlan2_ip}")

    timer.start(f"{step_label} - 建立 DUML 数据链路")
    loop = asyncio.get_running_loop()
    session = NanoSession(lambda k, p: None, loop)
    ok = await session.connect_direct(host="192.168.2.1", local_ip=wlan2_ip)
    if not ok:
        timer.stop("失败", "DUML 握手失败")
        raise RuntimeError("DUML 握手失败")

    if not session.status.is_photo:
        await session.set_mode(0x05)
    initial_files = await session.list_media()
    before_paths = {f.path for f in initial_files}
    timer.stop("成功", f"链路已通 (基线媒体数: {len(initial_files)})")
    return session, before_paths


async def disconnect_wifi_flow(
    session: NanoSession | None,
    timer: TimingLogger,
    step_label: str,
) -> None:
    """Disconnect session datalink and disconnect WLAN 2."""
    timer.start(f"{step_label} - 断开 Wi-Fi")
    if session:
        await session.disconnect()
    disconnect_wlan2()
    await asyncio.sleep(1.0)

    _, iface_text = _run_cmd(["netsh", "wlan", "show", "interfaces"])
    idx = iface_text.find("WLAN 2")
    wlan2_disconnected = idx != -1 and ("已断开连接" in iface_text[idx:] or "disconnected" in iface_text[idx:].lower())
    timer.stop(
        "成功" if wlan2_disconnected else "警告",
        f"WLAN 2已断开: {wlan2_disconnected}",
    )


async def main() -> int:
    timer = TimingLogger()
    ble_link = None
    session = None
    ble_keepalive_task = None
    captured_files: list[str] = []

    try:
        # -------------------------------------------------------------
        # 1. 连蓝牙 (BLE) 并唤醒
        # -------------------------------------------------------------
        timer.start("1. 连蓝牙 (BLE) 并唤醒相机")
        found = await scan(timeout=6.0)
        if not found:
            timer.stop("失败", "未扫描到 DJI 设备")
            return 1
        dev = found[0]
        mac = dev["address"]
        print(f"  找到设备: {dev['name']!r} ({mac}) RSSI: {dev['rssi']} dBm")

        ble_link = BleLink(on_log=lambda m: print(f"  [BLE Log] {m}"))
        await ble_link.connect(mac, timeout=10.0)
        await asyncio.sleep(0.5)

        # 唤醒相机与 SoftAP
        ble_link.send(commands.session_wake())
        ble_link.send(commands.session_5310())
        await asyncio.sleep(1.0)

        # 启动 BLE 保活泵
        async def _ble_keepalive():
            while ble_link and ble_link.client and ble_link.client.is_connected:
                ble_link.send(commands.session_keepalive())
                await asyncio.sleep(1.0)

        ble_keepalive_task = asyncio.create_task(_ble_keepalive())

        # 读取 Wi-Fi 凭证
        ssid, password = "", ""
        creds_file = os.path.join(HERE, "hw_creds.txt")
        if os.path.isfile(creds_file):
            with open(creds_file, encoding="utf-8") as f:
                ssid = f.readline().strip()
                password = f.readline().strip()
        if not ssid or not password:
            ssid, password = await ble_link.wifi_credentials(timeout=5.0)

        timer.stop("成功", f"MAC: {mac}, SSID: {ssid}")

        # -------------------------------------------------------------
        # 2. 连 Wi-Fi (第 1 次连接)
        # -------------------------------------------------------------
        session, before_paths = await connect_wifi_and_datalink(
            ssid, password, timer, "2. 连 Wi-Fi (第1次)", ble_link=ble_link
        )

        # -------------------------------------------------------------
        # 3. 拍一张取一张 (第 1 张)
        # -------------------------------------------------------------
        dest1, before_paths = await shoot_and_download(session, timer, "3. 拍第 1 张并取回", before_paths)
        captured_files.append(dest1)

        # -------------------------------------------------------------
        # 4. 隔 1 秒
        # -------------------------------------------------------------
        timer.start("4. 间隔等待 1 秒")
        await asyncio.sleep(1.0)
        timer.stop("成功", "等待 1.0s 完成")

        # -------------------------------------------------------------
        # 5. 再拍一张取一张 (第 2 张)
        # -------------------------------------------------------------
        dest2, before_paths = await shoot_and_download(session, timer, "5. 拍第 2 张并取回", before_paths)
        captured_files.append(dest2)

        # -------------------------------------------------------------
        # 6. 断 Wi-Fi (第 1 次断开)
        # -------------------------------------------------------------
        await disconnect_wifi_flow(session, timer, "6. 断开 Wi-Fi (第1次)")
        session = None

        # -------------------------------------------------------------
        # 7. 隔 1 秒
        # -------------------------------------------------------------
        timer.start("7. 间隔等待 1 秒 (保留蓝牙)")
        await asyncio.sleep(1.0)
        timer.stop("成功", "等待 1.0s 完成 (蓝牙保持在线)")

        # -------------------------------------------------------------
        # 8. 连 Wi-Fi (第 2 次连接)
        # -------------------------------------------------------------
        session, before_paths2 = await connect_wifi_and_datalink(
            ssid, password, timer, "8. 连 Wi-Fi (第2次)", ble_link=ble_link
        )

        # -------------------------------------------------------------
        # 9. 拍一张取一张 (第 3 张)
        # -------------------------------------------------------------
        dest3, before_paths2 = await shoot_and_download(session, timer, "9. 拍第 3 张并取回", before_paths2)
        captured_files.append(dest3)

        # -------------------------------------------------------------
        # 10. 断 Wi-Fi (第 2 次断开)
        # -------------------------------------------------------------
        await disconnect_wifi_flow(session, timer, "10. 断开 Wi-Fi (第2次)")
        session = None

        # -------------------------------------------------------------
        # 11. 断蓝牙 (完全断开)
        # -------------------------------------------------------------
        timer.start("11. 断开蓝牙 (BLE)")
        if ble_keepalive_task:
            ble_keepalive_task.cancel()
            ble_keepalive_task = None
        if ble_link:
            await ble_link.disconnect()
            ble_link = None
        timer.stop("成功", "蓝牙连接已安全释放")

        # -------------------------------------------------------------
        # 输出时间日志总结
        # -------------------------------------------------------------
        timer.print_summary()

        print("全流程测试圆满成功！本次测试共下载 3 张照片：")
        for idx, path in enumerate(captured_files, start=1):
            print(f"  照片 {idx}: {path}")
        return 0

    except Exception as exc:
        print(f"\n[ERROR] 测试过程中抛出异常: {exc}")
        import traceback
        traceback.print_exc()
        timer.stop("异常", str(exc))
        timer.print_summary()
        return 1

    finally:
        if session:
            try:
                await session.disconnect()
            except Exception:
                pass
        disconnect_wlan2()
        if ble_keepalive_task:
            ble_keepalive_task.cancel()
        if ble_link:
            try:
                await ble_link.disconnect()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
