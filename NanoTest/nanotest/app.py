"""NanoTest - a standalone Windows test bench for the DJI Osmo Nano.

Run:  python run.py            (real camera)
      python run.py --mock     (offline demo, no camera)
"""

from __future__ import annotations

import asyncio
import os
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from . import wifi
from .ble import BleLink, scan as ble_scan
from .ble_session import BleSession
from .mock import MockCamera
from .session import CAPTURE_DIR, NanoSession

VIDEO_W, VIDEO_H = 1280, 720
VIEW_W, VIEW_H = 800, 450


class Worker(threading.Thread):
    def __init__(self) -> None:
        super().__init__(daemon=True, name="nanotest-loop")
        self.loop = asyncio.new_event_loop()

    def run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def submit(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop)


class App:
    def __init__(self, root: tk.Tk, mock: bool = False, demo: bool = False) -> None:
        self.root = root
        self.mock_mode = mock
        self.demo = demo
        self.events: queue.Queue = queue.Queue()
        self._frame_lock = threading.Lock()
        self._latest_frame: bytes | None = None
        self._frame_seq = 0
        self._photo: tk.PhotoImage | None = None
        self._last_render = 0.0
        self._fps_shown = 0.0

        self.worker = Worker()
        self.worker.start()
        self.session = NanoSession(self.emit, self.worker.loop)
        self.ble: BleSession | None = None
        self.mock: MockCamera | None = None
        self._ble_link: BleLink | None = None
        self._devices: list[dict] = []

        self._build_ui()
        self.root.after(20, self._pump)
        if mock:
            self.root.after(300, self.start_mock)
        else:
            self.root.after(300, self._probe_wifi)
        if demo:
            self.root.lift()
            self.root.attributes("-topmost", True)
            self.root.after(9000, self.photo)

            def keep_on_top() -> None:
                try:
                    self.root.attributes("-topmost", True)
                    self.root.lift()
                except tk.TclError:
                    return
                self.root.after(1000, keep_on_top)

            self.root.after(500, keep_on_top)

    # -- ui --------------------------------------------------------------

    def _build_ui(self) -> None:
        self.root.title("NanoTest - DJI Osmo Nano bench")
        self.root.geometry("1280x900+10+10")
        self.root.configure(bg="#14171c")
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background="#14171c")
        style.configure("TLabel", background="#14171c", foreground="#d6dae0")
        style.configure("TButton", padding=4)
        style.configure("Head.TLabel", font=("Segoe UI", 10, "bold"), foreground="#8fb7ff")
        style.configure("Val.TLabel", foreground="#ffffff")

        top = ttk.Frame(self.root, padding=(8, 6))
        top.pack(fill="x")

        ttk.Button(top, text="Scan BLE", command=self.scan_ble).pack(side="left")
        self.device_var = tk.StringVar()
        self.device_box = ttk.Combobox(top, textvariable=self.device_var, width=38, state="readonly")
        self.device_box.pack(side="left", padx=6)
        ttk.Button(top, text="Pair + join Wi-Fi", command=self.pair_selected).pack(side="left")
        ttk.Button(top, text="BLE only", command=self.ble_only).pack(side="left", padx=(4, 0))

        ttk.Label(top, text="   SSID").pack(side="left")
        self.ssid_var = tk.StringVar(value="")
        ttk.Entry(top, textvariable=self.ssid_var, width=20).pack(side="left", padx=2)
        ttk.Label(top, text="Pass").pack(side="left")
        self.pass_var = tk.StringVar(value="")
        ttk.Entry(top, textvariable=self.pass_var, width=14, show="*").pack(side="left", padx=2)
        ttk.Button(top, text="Join + connect", command=self.join_wifi).pack(side="left", padx=4)
        ttk.Button(top, text="Connect now", command=self.connect_now).pack(side="left")
        ttk.Button(top, text="Disconnect", command=self.disconnect).pack(side="left", padx=4)
        self.autolive = tk.BooleanVar(value=True)

        body = ttk.Frame(self.root, padding=(8, 0))
        body.pack(fill="both", expand=True)

        # left: status
        left = ttk.Frame(body, width=330)
        left.pack(side="left", fill="y", padx=(0, 8))
        left.pack_propagate(False)
        ttk.Label(left, text="CAMERA STATUS", style="Head.TLabel").pack(anchor="w", pady=(2, 4))
        self.status_frame = ttk.Frame(left)
        self.status_frame.pack(fill="x")
        self.status_labels: dict[str, ttk.Label] = {}
        for row in self.session.status.rows():
            line = ttk.Frame(self.status_frame)
            line.pack(fill="x", pady=1)
            ttk.Label(line, text=row[0], width=16).pack(side="left")
            value = ttk.Label(line, text="-", style="Val.TLabel", anchor="w")
            value.pack(side="left", fill="x", expand=True)
            self.status_labels[row[0]] = value

        ttk.Separator(left).pack(fill="x", pady=6)
        ttk.Label(left, text="LINK", style="Head.TLabel").pack(anchor="w")
        self.link_label = ttk.Label(left, text="idle", justify="left")
        self.link_label.pack(anchor="w", pady=2)
        self.progress = ttk.Progressbar(left, mode="determinate", maximum=100)
        self.progress.pack(fill="x", pady=4)

        # center: video
        center = ttk.Frame(body)
        center.pack(side="left", fill="both", expand=True)
        self.video = tk.Label(
            center, bg="#05070a", fg="#6b7684", width=80, height=24,
            text="no picture\n\nLive ON starts the 720p25 stream",
        )
        self.video.pack(fill="both", expand=True)

        controls = ttk.Frame(center)
        controls.pack(fill="x", pady=6)
        ttk.Checkbutton(controls, text="auto live", variable=self.autolive).pack(side="left", padx=(0, 8))
        ttk.Button(controls, text="Live ON", command=self.live_on).pack(side="left")
        ttk.Button(controls, text="Live OFF", command=self.live_off).pack(side="left", padx=4)
        ttk.Button(controls, text="Re-enable (IDR)", command=self.live_reenable).pack(side="left")
        ttk.Separator(controls, orient="vertical").pack(side="left", fill="y", padx=8)
        ttk.Button(controls, text="PHOTO", command=self.photo).pack(side="left")
        ttk.Button(controls, text="Media list", command=self.media_list).pack(side="left", padx=4)
        ttk.Button(controls, text="Open captures", command=self.open_captures).pack(side="left")
        if not self.mock_mode:
            ttk.Button(controls, text="Mock camera", command=self.start_mock).pack(side="right")

        # bottom: log
        bottom = ttk.Frame(self.root, padding=(8, 4))
        bottom.pack(fill="x")
        ttk.Label(bottom, text="LOG", style="Head.TLabel").pack(anchor="w")
        self.log_text = tk.Text(bottom, height=9, bg="#0b0e12", fg="#b9c2cf",
                                insertbackground="#b9c2cf", font=("Consolas", 9), wrap="none")
        self.log_text.pack(fill="x")
        self.log_text.configure(state="disabled")

        self.state_var = tk.StringVar(value="idle")
        ttk.Label(bottom, textvariable=self.state_var).pack(anchor="w", pady=(2, 0))

    # -- events ----------------------------------------------------------

    def emit(self, kind: str, payload) -> None:
        if kind == "frame":
            with self._frame_lock:
                self._latest_frame = payload
                self._frame_seq += 1
            return
        self.events.put((kind, payload))

    def log(self, message: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"{stamp}  {message}\n")
        lines = int(self.log_text.index("end-1c").split(".")[0])
        if lines > 800:
            self.log_text.delete("1.0", f"{lines - 700}.0")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _pump(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.log(str(payload))
                elif kind == "state":
                    self.state_var.set(f"state: {payload}")
                elif kind == "status":
                    for label, value in payload.rows():
                        widget = self.status_labels.get(label)
                        if widget is not None:
                            widget.configure(text=str(value))
                elif kind == "media":
                    self.log(f"media: {len(payload)} item(s)")
                    for item in payload[:8]:
                        self.log(f"   {item.storage} {item.path}  {item.size_bytes} B")
                elif kind == "photo_saved":
                    self.log(f"photo saved: {payload}")
                elif kind == "progress":
                    done, total = payload
                    self.progress["value"] = 100.0 * done / total if total else 0
                elif kind == "ble_state":
                    self.state_var.set(f"state: BLE {payload}")
                elif kind == "ble_shot":
                    self.log("BLE shutter fired")
                elif kind == "devices":
                    self._devices = payload
                    labels = [f"{d['name'] or 'DJI'}  {d['address']}  {d['rssi']}dBm" for d in payload]
                    self.device_box["values"] = labels
                    if labels:
                        self.device_box.current(0)
                        self.log(f"BLE scan: {len(labels)} DJI device(s)")
                    else:
                        self.log("BLE scan: nothing found (is the camera awake and near?)")
                elif kind == "creds":
                    ssid, password = payload
                    self.ssid_var.set(ssid)
                    self.pass_var.set(password)
                    self.log(f"credentials from BLE: {ssid}")
                elif kind == "error":
                    self.log(f"ERROR: {payload}")
        except queue.Empty:
            pass

        self._render_frame()

        if self.session.connected:
            fps = self.session.measured_fps()
            self._fps_shown = fps
            dropped = self.session.depacketizer.dropped
            packets = self.session.datalink.video_packets if self.session.datalink else 0
            errors = self.session.decoder.decode_errors if self.session.decoder else 0
            self.link_label.configure(
                text=(
                    f"{self.session.host}   {'LIVE' if self.session.live else 'connected'}\n"
                    f"video {fps:4.1f} fps   packets {packets}\n"
                    f"dropped pictures {dropped}   decode errors {errors}\n"
                    f"media {len(self.session.media_files)} item(s)"
                )
            )
        elif self.ble and self.ble.connected:
            self.link_label.configure(
                text=(
                    f"BLE only   {self.ble.address}\n"
                    "status + mode + shutter over GATT\n"
                    "no video, no file download\n"
                    "(both need the camera Wi-Fi)"
                )
            )
        self.root.after(30, self._pump)

    def _render_frame(self) -> None:
        with self._frame_lock:
            data = self._latest_frame
            seq = self._frame_seq
            self._latest_frame = None
        if data is None:
            return
        now = time.time()
        if now - self._last_render < 0.03:
            return
        self._last_render = now
        try:
            from PIL import Image, ImageTk
        except ImportError:
            self.log("Pillow missing: pip install pillow")
            return
        image = Image.frombytes("RGB", (VIDEO_W, VIDEO_H), data)
        image = image.resize((VIEW_W, VIEW_H), Image.BILINEAR)
        self._photo = ImageTk.PhotoImage(image)
        self.video.configure(image=self._photo, text="")

    def _probe_wifi(self) -> None:
        ssid = wifi.current_ssid()
        if ssid:
            self.ssid_var.set(ssid)

    # -- actions ---------------------------------------------------------

    def scan_ble(self) -> None:
        self.log("scanning BLE (8 s)...")

        async def run() -> None:
            try:
                found = await ble_scan(8.0)
            except Exception as exc:  # noqa: BLE001
                self.emit("error", f"BLE scan failed: {exc}")
                return
            self.emit("devices", found)

        self.worker.submit(run())

    def _selected_device(self) -> dict | None:
        index = self.device_box.current()
        if index < 0 or index >= len(self._devices):
            return None
        return self._devices[index]

    def pair_selected(self) -> None:
        device = self._selected_device()
        if not device:
            messagebox.showinfo("NanoTest", "Scan and select a camera first.")
            return
        self.log(f"pairing with {device['name']} ({device['address']})")

        async def run() -> None:
            try:
                link = BleLink(on_log=self.log)
                self._ble_link = link
                await link.connect(device["address"])
                paired = await link.pair()
                if not paired:
                    self.emit("error", "pairing not confirmed (approve on the camera screen)")
                ssid, password = await link.wifi_credentials()
                await link.disconnect()
                self._ble_link = None
                if not ssid:
                    self.emit("error", "camera did not return an SSID")
                    return
                self.emit("creds", (ssid, password))
                ok = await self.session.connect_via_wifi(ssid, password)
                if ok and self.autolive.get():
                    await self.session.start_live()
            except Exception as exc:  # noqa: BLE001
                self.emit("error", f"pairing failed: {exc}")

        self.worker.submit(run())

    def ble_only(self) -> None:
        """Status + mode + shutter over GATT. No Wi-Fi, no internet drop."""
        device = self._selected_device()
        if not device:
            messagebox.showinfo("NanoTest", "Scan and select a camera first.")
            return
        self.log(f"BLE-only session with {device['name']} ({device['address']})")

        async def run() -> None:
            try:
                if self.ble:
                    await self.ble.disconnect()
                self.ble = BleSession(self.emit, self.worker.loop)
                await self.ble.connect(device["address"], device["name"] or "Osmo Nano")
            except Exception as exc:  # noqa: BLE001
                self.emit("error", f"BLE-only connect failed: {exc}")

        self.worker.submit(run())

    def join_wifi(self) -> None:
        ssid = self.ssid_var.get().strip()
        password = self.pass_var.get()
        if not ssid:
            messagebox.showinfo("NanoTest", "Enter the camera SSID (shown on its screen).")
            return
        self.log(f"joining {ssid}")

        async def run() -> None:
            if self.ble:
                await self.ble.disconnect()
            ok = await self.session.connect_via_wifi(ssid, password)
            if ok and self.autolive.get():
                await self.session.start_live()

        self.worker.submit(run())

    def connect_now(self) -> None:
        self.log("connecting on the current network (192.168.2.1)")

        async def run() -> None:
            if self.ble:
                await self.ble.disconnect()
            ok = await self.session.connect_direct()
            if ok and self.autolive.get():
                await self.session.start_live()

        self.worker.submit(run())

    def disconnect(self) -> None:
        async def run() -> None:
            if self.ble:
                await self.ble.disconnect()
            await self.session.disconnect()

        self.worker.submit(run())

    def live_on(self) -> None:
        if self.ble and self.ble.connected and not self.session.connected:
            self.log("live view needs Wi-Fi - BLE carries control and status only")
            return
        self.worker.submit(self.session.start_live())

    def live_off(self) -> None:
        self.worker.submit(self.session.stop_live())

    def live_reenable(self) -> None:
        self.worker.submit(self.session.reenable_live())

    def photo(self) -> None:
        ble_only = self.ble is not None and self.ble.connected and not self.session.connected
        if ble_only:
            self.log("PHOTO over BLE: switching to Photo and firing the shutter")
        else:
            self.log("PHOTO: switching to Photo mode and firing the shutter")

        async def run() -> None:
            try:
                if ble_only:
                    await self.ble.take_photo()
                    self.log("still is on the camera card - download needs Wi-Fi")
                else:
                    await self.session.take_photo(download=True)
            except Exception as exc:  # noqa: BLE001
                self.emit("error", f"photo failed: {exc}")

        self.worker.submit(run())

    def media_list(self) -> None:
        self.worker.submit(self.session.list_media())

    def open_captures(self) -> None:
        os.makedirs(CAPTURE_DIR, exist_ok=True)
        try:
            os.startfile(CAPTURE_DIR)  # type: ignore[attr-defined]
        except Exception:
            filedialog.askdirectory(initialdir=CAPTURE_DIR)

    def start_mock(self) -> None:
        if self.mock is not None:
            return
        self.log("starting mock camera (offline demo)")

        async def run() -> None:
            try:
                self.mock = MockCamera(http_port=18080, log=self.log)
                await self.mock.start()
                ok = await self.session.connect_direct(
                    "127.0.0.1", local_ip="127.0.0.1", media_host="127.0.0.1:18080"
                )
                if ok:
                    await self.session.start_live()
            except Exception as exc:  # noqa: BLE001
                self.emit("error", f"mock failed: {exc}")

        self.worker.submit(run())


def _enable_dpi_awareness() -> None:
    """Without this, Windows scales the window and the layout drifts."""
    if sys.platform != "win32":
        return
    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="DJI Osmo Nano test bench")
    parser.add_argument("--mock", action="store_true", help="run against the built-in fake camera")
    parser.add_argument("--demo", action="store_true", help="auto-run for screenshots")
    args = parser.parse_args(argv)

    _enable_dpi_awareness()
    root = tk.Tk()
    app = App(root, mock=args.mock, demo=args.demo)

    def on_close() -> None:
        try:
            app.worker.submit(app.session.disconnect())
            if app.mock:
                app.worker.submit(app.mock.stop())
        except Exception:
            pass
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()
    return 0
