"""Camera status decoding for the Osmo Nano.

Ported from OpenPocketCine / OpenCine (`CameraStatus+DJIWire.swift`), Apache-2.0.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .duml import Frame, u16, u32

SHOOTING_MODES = {
    0x00: "SlowMo",
    0x01: "Video",
    0x02: "TimeLapse",
    0x05: "Photo",
    0x0A: "HyperLapse",
    0x17: "Photo (Pocket 4)",
    0x28: "SuperNight",
    0x4D: "Live Photo",
    0x1A: "Live",
    0x3F: "PanoPhoto",
}

COLOR_MODES_NANO = {0x00: "Normal 8-bit", 0x3F: "Normal 10-bit", 0x3D: "D-Log M"}

RESOLUTIONS = {
    0x0A: ("1080p", "1920x1080", "16:9"),
    0x0C: ("1080p", "1920x1440", "4:3"),
    0x10: ("4K", "3840x2160", "16:9"),
    0x2D: ("2.7K", "2688x1512", "16:9"),
    0x5F: ("2.7K", "2688x2016", "4:3"),
    0x67: ("4K", "3840x2880", "4:3"),
    0x42: ("1080p", "1080x1920", "9:16"),
    0x43: ("2.7K", "1512x2688", "9:16"),
    0x69: ("1080p", "1080x1080", "1:1"),
    0x6A: ("2160p", "2160x2160", "1:1"),
    0x6B: ("3K", "3072x3072", "1:1"),
    0x6C: ("3K", "1728x3072", "9:16"),
}

FPS_INDEX = {
    0x01: 24, 0x02: 25, 0x03: 30, 0x04: 48, 0x05: 50, 0x06: 60,
    0x07: 120, 0x08: 240, 0x0A: 100, 0x13: 200, 0x0B: 96, 0x1D: 15,
}

ISO_INDEX = {
    0x00: "Auto", 0x02: "50", 0x03: "100", 0x04: "200", 0x05: "400",
    0x06: "800", 0x07: "1600", 0x08: "3200", 0x09: "6400", 0x0A: "12800",
    0x0B: "25600", 0x10: "9600", 0x11: "16000",
}

PHOTO_STORAGE = {0x00: "RAW", 0x01: "JPEG", 0x02: "JPEG+RAW"}


def parse_subscribe_push(payload: bytes):
    """`02 06 00 00 | idx | 00x3 | total_len | name_len | name | 00x6 | value_len | value`."""
    if len(payload) < 24 or payload[0] != 0x02 or payload[1] != 0x06:
        return None
    name_len = payload[13] | (payload[14] << 8)
    if not (0 < name_len < 80) or 15 + name_len + 8 > len(payload):
        return None
    name = payload[15 : 15 + name_len].decode("utf-8", "replace")
    if not name:
        return None
    value_len_at = 15 + name_len + 6
    if value_len_at + 2 > len(payload):
        return None
    value_len = payload[value_len_at] | (payload[value_len_at + 1] << 8)
    value_at = value_len_at + 2
    if value_at + value_len > len(payload):
        return None
    return name, payload[value_at : value_at + value_len]


def ev_label(raw: int) -> str:
    ev = (raw - 16) / 3.0
    return f"{ev:+.2f} EV".replace(".00", "")


@dataclass
class CameraStatus:
    firmware: str = ""
    # 0x02/0x80
    recording: bool = False
    in_playback: bool = False
    mode_byte: int = -1
    total_mb: int = 0
    free_mb: int = 0
    record_remaining_s: int = 0
    record_elapsed_s: int = 0
    # 0x02/0xDC
    sd_total_mb: int = 0
    sd_free_mb: int = 0
    internal_total_mb: int = 0
    internal_free_mb: int = 0
    # 0x0D/0x02
    battery_percent: int = -1
    battery_mv: int = 0
    battery_ma: int = 0
    docked: bool = False
    charging: bool = False
    # cam_expo_param
    expo_mode: int = -1
    shutter_denom: int = -1
    iso_index: int = -1
    iso_value: int = -1
    ev_raw: int = -1
    metered_ev_raw: int = -1
    # cam_video_param_v2
    res_byte: int = -1
    fps_index: int = -1
    # cam_image_effect
    color_byte: int = -1
    wb_mode: int = -1
    wb_kelvin: int = -1
    wb_tint: int = 0
    # misc
    timecode: str = ""
    record_time_s: int = 0
    photo_storage: int = -1
    model_name: str = ""
    last_push: dict = field(default_factory=dict)

    # -- derived ---------------------------------------------------------

    @property
    def mode_label(self) -> str:
        return SHOOTING_MODES.get(self.mode_byte, f"0x{self.mode_byte:02X}" if self.mode_byte >= 0 else "?")

    @property
    def is_photo(self) -> bool:
        return self.mode_byte in (0x05, 0x17)

    @property
    def resolution_label(self) -> str:
        if self.res_byte < 0:
            return "?"
        label, pixels, aspect = RESOLUTIONS.get(self.res_byte, ("?", "?", "?"))
        return f"{label} {aspect} ({pixels})"

    @property
    def fps(self) -> int:
        return FPS_INDEX.get(self.fps_index, 0)

    @property
    def color_label(self) -> str:
        return COLOR_MODES_NANO.get(self.color_byte, f"0x{self.color_byte:02X}" if self.color_byte >= 0 else "?")

    @property
    def shutter_label(self) -> str:
        return f"1/{self.shutter_denom}" if self.shutter_denom > 0 else "?"

    @property
    def iso_label(self) -> str:
        if self.iso_value > 0:
            return str(self.iso_value)
        return ISO_INDEX.get(self.iso_index, "?")

    @property
    def wb_label(self) -> str:
        if self.wb_mode < 0:
            return "?"
        name = "Auto" if self.wb_mode == 0 else ("Custom" if self.wb_mode == 6 else f"0x{self.wb_mode:02X}")
        if self.wb_kelvin > 0:
            return f"{name} {self.wb_kelvin}K"
        return name

    @property
    def battery_label(self) -> str:
        if self.battery_percent < 0:
            return "?"
        extra = []
        if self.charging:
            extra.append("charging")
        if self.docked:
            extra.append("dock")
        return f"{self.battery_percent}%" + (f" ({', '.join(extra)})" if extra else "")

    # -- update ----------------------------------------------------------

    def apply(self, frame: Frame) -> bool:
        p = frame.payload
        key = (frame.cmd_set, frame.cmd_id)

        if key == (0x00, 0x00) and len(p) >= 6:
            parts = [x.decode("utf-8", "replace") for x in p.split(b"\x00") if x]
            for part in reversed(parts):
                if 4 <= len(part) <= 24 and any(ch.isdigit() for ch in part):
                    self.firmware = part
                    return True
            return False

        if key == (0x02, 0x80) and len(p) >= 13:
            flags = u32(p, 0)
            self.in_playback = bool(flags & 0x4000_0000)
            self.recording = bool(flags & 0x0000_0080)
            total = u32(p, 5)
            free = u32(p, 9)
            if 1 <= total <= 50_000_000:
                self.total_mb = total
            if 0 <= free <= 50_000_000:
                self.free_mb = free
            if len(p) >= 21:
                self.record_remaining_s = u32(p, 17)
            if len(p) >= 31:
                self.record_elapsed_s = u16(p, 29)
            if len(p) >= 58:
                self.mode_byte = p[57]
            return True

        if key == (0x02, 0xDC) and len(p) >= 22:
            sd_total, sd_free = u32(p, 6), u32(p, 10)
            if sd_total or not self.sd_total_mb:
                self.sd_total_mb = sd_total
            if sd_free or not self.sd_free_mb:
                self.sd_free_mb = sd_free
            if len(p) >= 32:
                self.internal_total_mb = u32(p, 24)
                self.internal_free_mb = u32(p, 28)
            return True

        if key == (0x0D, 0x02) and len(p) >= 21:
            if len(p) >= 34:
                mv = p[1] | (p[2] << 8)
                if 2000 <= mv <= 5000:
                    self.battery_mv = mv
                ma = u32(p, 5)
                if ma & 0x8000_0000:
                    ma -= 1 << 32
                self.battery_ma = ma
                self.docked = p[27] != 0
                self.charging = p[32] == 1
            if 0 <= p[20] <= 100:
                self.battery_percent = p[20]
            return True

        if key == (0x00, 0x99):
            item = parse_subscribe_push(p)
            if not item:
                return False
            name, value = item
            self.last_push[name] = value
            return self._apply_push(name, value)

        return False

    def _apply_push(self, name: str, v: bytes) -> bool:
        if name == "cam_expo_param" and len(v) >= 8:
            self.expo_mode = v[7]
            auto = v[7] == 0x01
            if auto:
                if len(v) >= 23 and (v[21] & 0x80) and v[22] == 0:
                    denom = (v[20] | (v[21] << 8)) & 0x7FFF
                    self.shutter_denom = denom if 1 <= denom <= 16000 else -1
            elif len(v) >= 4:
                denom = (v[2] | (v[3] << 8)) & 0x7FFF
                self.shutter_denom = denom if 1 <= denom <= 16000 else -1
            if len(v) > 5:
                self.iso_index = v[5]
            if len(v) >= 18:
                iso = u16(v, 16)
                if 50 <= iso <= 102_400:
                    self.iso_value = iso
            if len(v) > 6:
                self.ev_raw = v[6]
            if len(v) > 15:
                self.metered_ev_raw = v[15]
            return True

        if name == "cam_video_param_v2" and len(v) >= 2:
            self.res_byte = v[0]
            self.fps_index = v[1]
            return True

        if name == "cam_image_effect" and len(v) > 2:
            self.color_byte = v[2]
            if len(v) >= 8:
                self.wb_mode = v[4]
                kelvin = (v[5] | (v[6] << 8)) * 100
                if 2000 <= kelvin <= 10000:
                    self.wb_kelvin = kelvin
                tint = v[7] | (v[8] << 8) if len(v) >= 9 else 0
                if tint >= 0x8000:
                    tint -= 1 << 16
                self.wb_tint = tint
            return True

        if name == "cam_record_time" and len(v) >= 4:
            self.record_time_s = u32(v, 0)
            return True

        if name == "timecode_info" and len(v) >= 8:
            self.timecode = f"{v[3]:02d}:{v[4]:02d}:{v[5]:02d}:{v[6]:02d}"
            return True

        if name == "camcap_photo_storage_format" and len(v) >= 1:
            self.photo_storage = v[0]
            return True

        return False

    def rows(self):
        """(label, value) pairs for the GUI."""
        total_gb = self.total_mb / 1024 if self.total_mb else 0
        free_gb = self.free_mb / 1024 if self.free_mb else 0
        sd = f"{self.sd_free_mb / 1024:.1f}/{self.sd_total_mb / 1024:.1f} GB" if self.sd_total_mb else "-"
        internal = (
            f"{self.internal_free_mb / 1024:.1f}/{self.internal_total_mb / 1024:.1f} GB"
            if self.internal_total_mb
            else "-"
        )
        return [
            ("Model", self.model_name or "Osmo Nano"),
            ("Firmware", self.firmware or "?"),
            ("Battery", self.battery_label),
            ("Mode", self.mode_label),
            ("Recording", "REC" if self.recording else ("playback" if self.in_playback else "idle")),
            ("Elapsed", f"{self.record_elapsed_s}s"),
            ("Remaining", f"{self.record_remaining_s // 60} min"),
            ("Video", f"{self.resolution_label} @ {self.fps}fps" if self.fps else self.resolution_label),
            ("Color", self.color_label),
            ("ISO", self.iso_label),
            ("Shutter", self.shutter_label),
            ("EV", ev_label(self.ev_raw) if self.ev_raw >= 0 else "?"),
            ("Metered EV", ev_label(self.metered_ev_raw) if self.metered_ev_raw >= 0 else "?"),
            ("White balance", self.wb_label),
            ("Photo format", PHOTO_STORAGE.get(self.photo_storage, "?")),
            ("Storage (active)", f"{free_gb:.1f}/{total_gb:.1f} GB" if total_gb else "-"),
            ("SD card", sd),
            ("Internal", internal),
            ("Timecode", self.timecode or "-"),
        ]
