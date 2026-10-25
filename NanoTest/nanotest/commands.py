"""DUML frame builders for the connection spine, control, media and live view.

Ported from OpenPocketCine / OpenCine (`Commands.swift`), Apache-2.0.
Osmo Nano specifics:
  * live-view enable receiver is 0x41 (Pocket is 0x08; 0x08 is rejected with E0)
  * live view additionally needs the Nano gate `0x02/0x09` ...03 / ...04
  * Photo shooting mode is 0x05 (0x17 is Pocket 4 and answers 0xEE on a Nano)
"""

from __future__ import annotations

from .duml import (
    FLAG_ACK_80,
    FLAG_REQUEST,
    FLAG_RESPONSE,
    RX_1C,
    RX_CAMERA,
    RX_SESSION,
    RX_WIFI,
    SENDER_APP,
    Frame,
    le16,
    le32,
    pack_string,
)

DEFAULT_IDENTIFIER = "284ae5b8d76b3375a04a6417ad71bea3"
PAIRING_TOKEN = "osmo"

#: 0x00/0x99 status keys, subId starting at 0x69DF.
SUBSCRIPTION_KEYS = [
    "camcap_mode_profile",
    "camcap_video_format",
    "camcap_fov",
    "camcap_iso",
    "camcap_shutter",
    "camcap_photo_storage_format",
    "camcap_color_mode",
    "cam_storage",
    "cam_status",
    "timecode_info",
    "cam_expo_param",
    "cam_video_param_v2",
    "cam_record_time",
    "cam_image_effect",
    "cam_lens_state",
    "cam_fov",
    "cam_audio_status_v2",
]
FIRST_SUB_ID = 0x69DF


def rx(type_: int, ident: int) -> int:
    return (ident << 5) | type_


def _camera(cmd_id: int, payload: bytes, seq: int = 0) -> Frame:
    return Frame(SENDER_APP, RX_CAMERA, seq, FLAG_REQUEST, 0x02, cmd_id, payload)


# ---- BLE session sequence (written to FFF5) ---------------------------------


def session_wake(seq: int = 0x802B) -> Frame:
    return Frame(SENDER_APP, RX_SESSION, seq, FLAG_REQUEST, 0x00, 0x2B, b"\x04\x00")


def session_keepalive(seq: int = 0x802B) -> Frame:
    return Frame(SENDER_APP, RX_SESSION, seq, FLAG_REQUEST, 0x00, 0x2B, b"\x01\x01")


def set_pairing_pin(seq: int = 0x8092, pin: str = PAIRING_TOKEN) -> Frame:
    return Frame(
        SENDER_APP,
        RX_WIFI,
        seq,
        FLAG_REQUEST,
        0x07,
        0x45,
        pack_string(DEFAULT_IDENTIFIER) + pack_string(pin),
    )


def pair_approval_ack(seq: int) -> Frame:
    return Frame(SENDER_APP, RX_WIFI, seq, FLAG_RESPONSE, 0x07, 0x46, b"\x00")


def session_5310(seq: int = 0x8053) -> Frame:
    """Camera answers `01 00 00 00` and wakes its SoftAP."""
    return Frame(SENDER_APP, RX_1C, seq, FLAG_REQUEST, 0x53, 0x10, b"\x00\x00\x00\x00")


def get_wifi_ssid(seq: int = 0x8007) -> Frame:
    return Frame(SENDER_APP, RX_WIFI, seq, FLAG_REQUEST, 0x07, 0x07, b"")


def get_wifi_password(seq: int = 0x800E) -> Frame:
    return Frame(SENDER_APP, RX_WIFI, seq, FLAG_REQUEST, 0x07, 0x0E, b"")


# ---- Datalink registration ---------------------------------------------------


def app_device_info(seq: int) -> Frame:
    """`0x00/0x81` device-info, cmdType 4 (flags 0x80) -> DM368 (type 0x08, id 2)."""
    b = bytearray(62)
    b[1] = 0x41  # 'A'
    b[2] = 0x50  # 'P'
    b[3] = 0x50  # 'P'
    b[41] = 0x02
    b[50] = 0x02
    b[51] = 0x08
    return Frame(SENDER_APP, rx(0x08, 2), seq, 0x80, 0x00, 0x81, bytes(b))


APP_PRESENCE = bytes(
    [0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]
)


def app_presence_frame(seq: int) -> Frame:
    """`0x00/0x88` app-presence, re-sent ~1 Hz to hold the session."""
    return Frame(SENDER_APP, rx(0x08, 1), seq, FLAG_REQUEST, 0x00, 0x88, APP_PRESENCE)


def subscribe(key: str, sub_id: int, seq: int = 0) -> Frame:
    name = key.encode("utf-8")
    p = bytearray([0x02, 0x02, 0x00, 0x00])
    p += le32(sub_id)
    p += b"\x00\x00\x00"
    p += le16(len(name) + 6)
    p += le16(len(name))
    p += name
    p += b"\x00\x00\x00\x00"
    return Frame(SENDER_APP, rx(0x08, 1), seq, FLAG_REQUEST, 0x00, 0x99, bytes(p))


# ---- Camera control ---------------------------------------------------------


def live_view_enable(seq: int = 0, receiver: int = 0x41) -> Frame:
    """`0x09/0xA8` start live view / IDR request (Nano receiver 0x41)."""
    return Frame(
        SENDER_APP,
        receiver,
        seq,
        FLAG_REQUEST,
        0x09,
        0xA8,
        bytes([0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
    )


def nano_live_gate(start: bool, seq: int = 0) -> Frame:
    """`0x02/0x09` Nano gate, sent once before the enable and with stop."""
    return _camera(0x09, bytes([0] * 10 + [0x03 if start else 0x04]), seq)


def shoot_photo(seq: int = 0) -> Frame:
    """`0x02/0x01` payload `01` - stills in Photo mode; Video answers `D9`."""
    return _camera(0x01, b"\x01", seq)


def record_start(seq: int = 0) -> Frame:
    return _camera(0x02, b"\x01", seq)


def record_stop(seq: int = 0) -> Frame:
    return _camera(0x02, b"\x00", seq)


def set_shooting_mode(mode_byte: int, seq: int = 0) -> Frame:
    """`0x02/0xE1`. Sparse: only tabled bytes. Nano Photo = 0x05."""
    return _camera(0xE1, bytes([mode_byte & 0xFF]), seq)


def set_video_format(res: int, fps_index: int, seq: int = 0) -> Frame:
    """`0x02/0x18` normal Video `[res][fps][00 00 00]`."""
    return _camera(0x18, bytes([res & 0xFF, fps_index & 0xFF, 0, 0, 0]), seq)


def param_get(pid: int, seq: int = 0) -> Frame:
    """`0x02/0x8E` GET `[00 01 pid_lo pid_hi]`; reply `00 00 01 pid 01 value`."""
    return _camera(0x8E, bytes([0x00, 0x01, pid & 0xFF, (pid >> 8) & 0xFF]), seq)


def enter_playback(seq: int = 0) -> Frame:
    return _camera(0x0C, b"\x01\x01\x00\x01", seq)

def exit_playback(seq: int = 0) -> Frame:
    return _camera(0x0C, b"\x01\x01\x00\x00", seq)


# ---- Media list -------------------------------------------------------------

LIST_TEMPLATE = bytes(
    [
        0x4A, 0x00, 0x2A, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2D, 0x00, 0x0D, 0x01, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    ]
)

LIST_TRIGGER = bytes(
    [0x4A, 0x04, 0x0E, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
)


def media_list(counter: int, cursor: int, seq: int = 0) -> Frame:
    p = bytearray(LIST_TEMPLATE)
    p[4] = counter & 0xFF
    p[10:14] = le32(cursor & 0xFFFFFFFF)
    return Frame(SENDER_APP, RX_CAMERA, seq, FLAG_REQUEST, 0x00, 0x26, bytes(p))


def media_list_trigger(seq: int = 0) -> Frame:
    return Frame(SENDER_APP, RX_CAMERA, seq, FLAG_REQUEST, 0x00, 0x26, LIST_TRIGGER)


def delete_media(handle: int, counter: int, seq: int = 0) -> Frame:
    p = bytearray([0x01])
    p += le32(handle)
    p += le32(counter)
    p += b"\x00"
    p += le32(1)
    p += b"\x01\x01\x00\x00"
    return Frame(SENDER_APP, RX_CAMERA, seq, FLAG_REQUEST, 0x00, 0x28, bytes(p))
