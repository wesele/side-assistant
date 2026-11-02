# DJI Osmo Nano 逆向研究笔记

> 研究对象：DJI Osmo Nano（BLE model id `0x0019`，固件为 2026-10 在售版本）
> 方法：阅读 [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) / [OpenCine](https://github.com/erik-sutton95/OpenCine) 的逆向实现，在真机上逐条验证并补齐 Windows 侧实现
> 配套程序：[`NanoTest/`](NanoTest/)（Windows，Python + tkinter）
> 实测日期：2026-10-18

---

## 0. 结论速览

| 问题 | 结论 |
| --- | --- |
| live stream 格式 | **1280×720 / AVC(H.264) High / 约 29–30 fps / 约 4 Mbit/s**，走 Wi-Fi 的 UDP 9004 私有 DUML 流；**没有任何命令可以改分辨率、码率、帧率** |
| 与录制格式的关系 | 完全独立。录制 2.7K50 / 4K 时预览仍是 720p |
| 是否支持"只拍照" | **支持**。相机有 Photo 模式（`0xE1 05`）+ 快门（`0x02/0x01`）。实测快门响应约 **10 ms**；"未开流 + 拍照 + HTTP 下载"已在真机全面验证（单张闭环约 1.6~1.8 s） |
| 只用蓝牙能不能拍照 | **能**。状态、切模式、按快门都可走 GATT；但**取不到照片、也看不到画面** |
| 只用蓝牙能不能看图 | **不能**。视频只在 UDP 9004；照片只在 HTTP `/v2`（Wi-Fi SoftAP） |
| 双网卡免断网导图 | **支持**。主网卡保外网，副网卡（WLAN 2）专用连 Nano SoftAP（入网约 0.36~0.45 s），实现无感拉图 |
| 配对是什么 | **应用层 PIN 交换**，不是蓝牙绑定；只用来解锁 Wi-Fi 密码，GATT 控制通道不校验它 |

---

## 1. 连接拓扑

```
                    ┌── BLE GATT (FFF0)
                    │     ├─ 配对 / 唤醒 / 取 Wi-Fi 凭据
相机 Osmo Nano ─────┤     ├─ 状态推送 (00/99, 02/80, 0D/02)
                    │     └─ 控制 (02/E1 模式, 02/01 快门)  ← 真机可用
                    │
                    └── Wi-Fi SoftAP 192.168.2.1 (WPA2)
                          ↑ [推荐] 专用副网卡 WLAN 2 绑定连接，主网卡保持外网互不干扰
                          ├─ TCP 7001   poke 会话
                          ├─ UDP 9004   握手 / 命令 / 遥测 / 视频
                          └─ HTTP 80    /v2?storage=&path= 取文件
```

- 相机同时开 BLE 与 SoftAP。BLE 不依赖 Wi-Fi，Wi-Fi 也不依赖 BLE 已连接。
- **SoftAP 空闲会自动关闭**；需要时用 BLE `0x53/0x10` 唤醒（见 §2.3）。
- **多网卡系统命令要求**：在多网卡环境下执行 `netsh wlan connect/disconnect` 必须显式指定 `interface="WLAN X"`。

---

## 2. BLE：配对、状态、控制

### 2.1 GATT

| 角色 | UUID | 属性 |
| --- | --- | --- |
| Service | `0000FFF0-…` | — |
| FFF3 | `0000FFF3-…` | read / indicate / notify / write |
| **FFF4** | `0000FFF4-…` | notify + **arm pairing**（写 `01 00`，with response） |
| **FFF5** | `0000FFF5-…` | **命令写入**（write-without-response，需限速） |
| FFF7 | `0000FFF7-…` | read / indicate / notify / write |

- 实测 MTU = **517**。
- FFF5 写入必须**限速**（仓库记录 100–500 ms；本实现用 120 ms），否则会丢帧。
- 写入内容是完整 DUML 帧（`55 len ver crc8 …crc16`），不额外分片。
- 通知流不是 DUML 边界，需要按 `0x55` + 长度 + CRC8/CRC16 重新拼帧。

### 2.2 配对：它到底管什么

`0x07/0x45`（SetPairingPIN）载荷是 `[len]identifier[len]"osmo"`，identifier 默认用 Osmosis 的
`284ae5b8d76b3375a04a6417ad71bea3`（相机按 identifier 记住授权）。

| 相机回复 | 含义 |
| --- | --- |
| `00 01` | 已配对 |
| `00 02` | 需要在相机屏幕上确认 |
| `00 06` | 暂时拒绝（等几秒重试） |
| 相机发 `0x07/0x46` 请求 | 审批请求，用 flags `0xC0` + payload `00` 回应 |

**关键结论（真机验证）**：

- 未配对（`00 02`）状态下，相机**仍然接受 GATT 上的控制命令**；
- 配对只解锁 **Wi-Fi 凭据**：`0x07/0x07`（SSID）、`0x07/0x0E`（密码）；
- 配对弹窗只在相机**亮屏**时出现，息屏/待机时不画；
- 用户点"允许"后，`0x07/0x45` 立刻变成 `00 01`，随后可读到 SSID 与 12 位密码。

### 2.3 唤醒与"待机陷阱"

- **自动休眠机制**：不断开蓝牙，相机在无操作超时后**仍会自动息屏进入休眠待机**（此时 5GHz SoftAP 会自动关停省电，但 BLE 链路保持连接且继续推送遥测帧）。
- **待机陷阱**：在休眠待机时发送控制命令（切模式/快门），相机 BLE 层会**静默回复 ACK `00` 但机身不执行**（模式不变，快门回复 `D9 wrong state`）。
- **长效保活**：客户端以约 1 Hz 持续发送 `0x00/0x2B [01 01]`（session keepalive）可维持相机活动，防止进入待机。
- **远程唤醒**：待机后无需重连蓝牙，按序发送两帧指令即可秒级拉起主控与 SoftAP：
  ```text
  0x00/0x2B  [04 00]          session wake（唤醒主控）
  0x53/0x10  [00 00 00 00]    拉起 SoftAP（相机亮屏并回传 01 00 00 00）
  ```
  唤醒后命令立刻生效：`E1 05 → 00 (@57: 1→5)`，`02/01 → 00`。

### 2.4 BLE 能做什么（真机数据）

| 能力 | 结果 |
| --- | --- |
| 状态推送 | ✅ 2 s 内 47 条（`00/99`、`02/80`、`0D/02`），约 80 帧/s |
| 电量 | ✅ 例：88%，charging，docked |
| 切模式 | ✅ `02/E1 05` / `01`，`02/80 @57` 确认 |
| 快门 | ✅ `02/01 01` → `00`（Video 模式下回 `D9`） |
| 读 Wi-Fi 凭据 | ✅ 仅在配对后 |
| 实时画面 | ❌ 协议无通道；带宽也不够（见下） |
| 取照片 | ❌ 没有文件通道 |

带宽账：720p25 的 AVC 预览约 4 Mbit/s；BLE 5 在 517 B MTU 下实际上限约 1 Mbit/s 量级，
且视频根本没有 BLE 封装。**所以"纯蓝牙看图"不可行，纯蓝牙遥控拍照可行。**

---

## 3. Wi-Fi：DUML datalink

### 3.1 入网与 TCP poke

1. 加入 `OsmoNano-*` 热点（WPA2），拿到 `192.168.2.x`。
2. 连 `192.168.2.1:7001`，写一帧裸 DUML `SetPairingPIN`，**socket 全程保持打开**
   （关掉会 RST 相机）。
3. 开 UDP：本地用**临时端口**绑定到 192.168.2.x，目标是 `192.168.2.1:9004`。
   **不要**把本地绑到 9004。

### 3.2 握手 / 初始窗口 / ACK / 注册

- 握手：`pktType 0x00`，48 字节（8 B transport + 40 B payload），payload 前两字节是
  **8 对齐的随机 baseSeq**，其余固定（窗口 100，MTU 1472）。
- 相机回 `pktType 0x00` 即握手成功。
- **首个命令序列**不能用自己的 baseSeq，要等相机第一帧 **34 字节 `pktType 0x01`**，
  取 `bytes[8..9] + 8` 作为起始 `udpSeq`。取错会"写得进去但相机不执行"。
- 窗口 ACK：`pktType 0x04`，26 B 载荷，三组 cursor（video / reliable / extra），
  **25 ms 一次（40 Hz）**；1 Hz 会让发送窗口停住。
- 注册：`0x00/0x81`（device-info）+ `0x00/0x88`（presence），**1 Hz**；停发 8–10 s 后相机会停视频。
- 订阅：`0x00/0x99`，subId 从 `0x69DF` 起，17 个 key。

### 3.3 命令封装

```
[8B transport hdr][12B routing hdr][DUML frame]
transport: u16(0x8000|total) session seq pktType xor
routing:   u16(udpSeq-8) u16(udpSeq) 00 00 00 00 cmdCounter 01 00 00
```

**关键：`0x02/0xE1` 是稀疏枚举，绝对不要扫值域**——仓库记录扫这个 opcode 会把 Nano 冻死、要扣电池。

---

## 4. Live view

### 4.1 实测格式

| 项 | 值 |
| --- | --- |
| 编码 | AVC / H.264 **High**（`avc1.64001f`），明文 Annex-B |
| 分辨率 | **1280×720** |
| 帧率 | **实测约 29–30 fps**（仓库记录 ~25，随固件/模式变化，别写死） |
| 码率 | ~4 Mbit/s 量级 |
| 传输 | DUML `pktType 0x02`，UDP 9004，单播单客户端 |
| 与录制格式 | **无关**（录制 2.7K50 时预览仍 720p） |

### 4.2 开流序列（Nano 专用）

```
0x02/0x09  payload 00×10 03        ← Nano gate，先发
0x09/0xA8  payload 00 04 02 00…    receiver 0x41   ← 同时是 IDR 请求
```

- Pocket 用 receiver `0x08`；对 Nano 发 `0x08` 会回 `E0` 且**一个视频包都没有**。
- 不要每秒重发 `0xA8`：会重置 GOP 时钟，关键帧永远等不到。
- 没有"停止推流"命令；停流只能不续注册/断 socket。

### 4.3 分片与帧结构

- 每个数据包：`[8B transport][12B fragment][payload]`。
- 帧以 16 字节 DJI 头开始：`00 00 01 FF` + `u32 LE 编码字节数` + 8 字节元数据。
  接收端按声明长度收满后，丢掉 16 字节头，得到 Annex-B 访问单元。
- 大图会跨 transport group（单组最多 63 包）；**只能按声明长度收尾**。
- 实测一帧的 NAL 结构：

```
IDR 帧:  [SPS 7][PPS 8][IDR slice 5][SEI 6][AUD 9]
P  帧:  [slice 1][SEI 6][AUD 9]
私有 SEI: 06 F0 19 + 25 字节元数据 + 80      ← 内部可能含未转义的 00 00 01
```

### 4.4 解码的三个真机坑（都已修）

1. **Windows UDP 接收缓冲**默认 64 KB，而开流瞬间的 IDR 约 95 KB，会丢开头 1–2 包 →
   缺 SPS/PPS → 全黑 + 刷 `non-existing PPS 0 referenced`。
   修法：绑定后立刻 `SO_RCVBUF = 4 MB`，并在 3 s 没画面时补发一次 enable。
2. **ffmpeg 管道参数**：`-fflags nobuffer -flags low_delay` 在 `pipe:0` 上把同一段码流
   从 214 帧压到 **2 帧**。去掉，只留 `-probesize 65536 -analyzeduration 0 -threads 1`。
3. **私有 SEI 不能按起始码扫描**：25 字节元数据里故意有 `00 00 01`，
   任何"清洗 NAL"的实现都会切错。原样把访问单元喂给 ffmpeg。

---

## 5. 拍照与取图

### 5.1 模式与快门

```
0x02/0xE1  [05]    Photo（Pocket 3/Nano；Pocket 4 是 0x17，发 0x17 到 Nano 回 0xEE）
0x02/0x01  [01]    快门；Video 模式下回 D9
```

- 切模式后等 `0x02/0x80 @57` 回显确认，再按快门。
- **BLE 与 Wi-Fi 两条通道都能完成这一步**（真机验证）。

### 5.2 媒体列表

```
0x00/0x26  [4A …][counter @4][cursor @10..13]
           counter 1 = SD，counter 2 = 内置；最新页 cursor = 1 / 0x40000001
0x00/0x27  [10B sub][chunk]：subtype 04 开始 / 01 数据 / 03 结束
```

- 最新一页**不需要进 playback**；更早的页需要 `0x02/0x0C`。
- 分片走 ACK-window group 1，需要 40 Hz ACK，否则清单会中途停。
- 记录是 CompositePack TLV：`1A len 00 00 00 01 <DCIM 路径不带扩展名>`，
  扩展名在单独的 `0D len "<base>.<EXT>"` 字段里，handle 在路径前 17 字节。

### 5.3 下载

```
GET http://192.168.2.1/v2?storage={0|1}&path=DCIM/DJI_001/xxx.JPG
```

- `storage`：SD = 0，内置 = 1（可从 handle 的 `0x40000000` 位判断）。
- 相机**从不主动推送**照片；必须"列表 → 按 handle 取路径 → HTTP 拉"。

### 5.4 实测指标

| 项 | 值 | 说明 |
| --- | --- | --- |
| 快门响应 | **约 10 ms**（0.010 s） | 指令发出至相机返回 `00` 回执 |
| SoftAP 入网 | **约 0.36 ~ 0.45 s** | 副网卡（WLAN 2）802.11 握手与 DHCP 获取 `192.168.2.x` |
| DUML 握手建链 | **约 0.36 ~ 3.9 s** | TCP 7001 poke + UDP 9004 握手（首次建链稍长，重连极快） |
| 单张闭环吞吐 | **约 1.6 ~ 1.8 s** | 快门触发 → 落盘 → 清单检索 → HTTP 下载完成（~1 MB JPEG） |
| 连拍能力 | **间隔 1.0 s** 稳定通过 | 连续触发并拉取多张无丢包、清单刷新正常 |
| 断网重连链路 | **断开 1.0 s 后重连全通** | 断开 Wi-Fi 期间 BLE 遥测持续正常；重连后 0.36 s 重新建立数据链路 |

---

## 6. 状态读取

| 来源 | 内容 |
| --- | --- |
| `0x02/0x80` | flags（bit7 录制、bit30 playback）、存储 MB `@5/@9`、剩余 `@17`、已录 `u16@29`、**模式 `@57`** |
| `0x02/0xDC` | SD `@6/@10`，内置 `@24/@28`（MiB） |
| `0x0D/0x02` | 电量 `@20`、mV `@1`、mA `@5`、docked `@27`、charging `@32` |
| `0x00/0x99` | `cam_expo_param`（模式/快门/ISO/EV）、`cam_video_param_v2`（res/fps）、`cam_image_effect`（色彩/白平衡）、`cam_record_time`、`timecode_info`、`cam_storage`、`camcap_*` 能力表 |

这些 key 在 **BLE 未配对时也会推**，所以纯蓝牙就能读状态。

---

## 7. 真机验证矩阵

| 环节 | 状态 | 证据 |
| --- | --- | --- |
| 协议字节 | ✅ | 配对帧 51 B `55 33 04 C2 02 07 92 80 40 07 45`；订阅 29/30/38 B |
| BLE 扫描 | ✅ | `OsmoNano-…`，model `0x0019`，RSSI −46 |
| GATT / arm / 唤醒 | ✅ | 写 `01 00`，`53/10` 回 `01 00 00 00` |
| BLE 配对 | ✅ | 屏幕点允许后 `07/45 = 00 01`，读到 SSID + 12 位密码 |
| BLE-only 控制 | ✅ | `E1 05` → `00`，模式 1→5；`02/01` → `00` |
| Wi-Fi 入网 | ✅ | DHCP `192.168.2.147` / `192.168.2.161` |
| UDP 握手 | ✅ | `handshake ACK` + 初始窗口 |
| live view | ✅ | 8 s **233 帧，约 29–30 fps，2516 包，0 丢帧** |
| 拍照 + 下载 | ✅ | 4 张 3712×2088 JPEG（约 1 MB） |
| 从不开流只拍照 | ✅ | 真机已验证，快门约 10 ms，未开流下连续取回多张 JPEG |
| 双网卡免断网导图 | ✅ | 主网卡保持外网，副网卡 WLAN 2 连 SoftAP，单张闭环 ~1.7 s |
| 多轮连拍与重连 | ✅ | 连拍 2 张 → 断 Wi-Fi (保 BLE) → 重连 Wi-Fi 拍第 3 张，全通 |

---

## 8. Windows 实现：`NanoTest`

独立的 Python 程序（`NanoTest/`），不依赖手机/官方 SDK：

- `nanotest/duml.py` `transport.py` `commands.py` — DUML、握手、窗口 ACK、全部命令字节
- `nanotest/datalink.py` — UDP 9004（SO_RCVBUF、40 Hz ACK、1 Hz 注册、首窗口）
- `nanotest/video.py` — 分片重组 + ffmpeg 管道解码
- `nanotest/media.py` — 媒体清单解析 + HTTP 下载
- `nanotest/ble.py` `ble_session.py` — BLE 配对、唤醒、状态、快门
- `nanotest/session.py` — Wi-Fi 业务流程
- `nanotest/mock.py` — 本机假相机（无硬件也能跑通全链路）
- `nanotest/app.py` — tkinter 界面（BLE only / 配对入网 / 实时画面 / 拍照 / 状态）
- `tools/test_wlan2_capture.py` — 双网卡全流程测试脚本（连蓝牙、连 Wi-Fi、连拍、断连、重连、断开全流程与各阶段精确计时）

三种模式：**BLE only**（不断网，遥控）、**配对入网**（完整功能）、**手动 SSID/密码**。

---

## 9. 未解与风险

- **多网卡 netsh 限制**：机器存在多个无线网卡时，`netsh wlan connect/disconnect` **必须显式声明 `interface="WLAN X"`**，否则 Windows 报错拒绝执行。
- **触发即冻结**：`0x02/0xE1` 扫值域会把 Nano 冻死；只发已知值。
- **单客户端**：视频只发往一个 UDP 5 元组，不能两个程序同时看。
- **首帧脆弱**：IDR 丢一个包就整段黑，只能补 enable；没有 NACK/重传。
- **待机静默 ACK**：命令回 `00` 不代表执行，必须先唤醒。
- **帧率不固定**：仓库 ~25、实测 ~29–30，说明随固件/拍摄模式变化。
- **照片尺寸取决于相机设置**：16:9 是 3712×2088，4:3 才是 6880×5160。
- 超出本笔记：SlowMo/Timelapse/Hyperlapse 的参数、gimbal（Nano 无）、RTMP 推流（Nano 不支持）。

---

## 10. 参考资料

- OpenPocketCine 协议手册：<https://opencapture.org/openpocketcine/docs/protocol/>
  - live view：`protocol/live-view/`，命令表：`protocol/commands/`，HTTP：`protocol/media/`，BLE：`protocol/ble/`
- OpenPocketCine 仓库：<https://github.com/erik-sutton95/OpenPocketCine>
  - `docs/osmo-recording-formats.md`、`docs/protocol-notes.md`、`docs/research-nano-station-wifi.md`
- OpenCine 仓库（协议实现）：<https://github.com/erik-sutton95/OpenCine>
  - `Sources/OpenCineDJI/{DumlFrame,DumlTransport,Commands,HevcDepacketizer}.swift`
- DJI 官方规格：<https://www.dji.com/nano/specs>
- 本仓库实测产物：`NanoTest/hw_frame.png`（实拍帧）、`NanoTest/captures/DJI_2026*_D.JPG`（下载静帧）
