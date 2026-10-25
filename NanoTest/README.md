# NanoTest — DJI Osmo Nano Windows 测试台

> 协议与实测结论的完整整理见上级目录的 [`../nano.md`](../nano.md)。

一个独立的 Windows 小程序，用来验证 Osmo Nano 的 **BLE 配对 / Wi-Fi 连接 / 实时画面 / 拍照回传 / 状态读取**。
协议来自 [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) 与 [OpenCine](https://github.com/erik-sutton95/OpenCine)（Apache-2.0）的逆向结果，本程序是独立的 Python 重写，不依赖 iOS/Android。

```
                   ┌── BLE FFF0/FFF4/FFF5 ── 配对、状态、模式、快门（不占网络）
相机 Osmo Nano ────┤
                   └── Wi-Fi SoftAP 192.168.2.1
                         ├─ UDP 9004  pktType 0x02 → H.264 720p25 → ffmpeg
                         ├─ 0x09/0xA8 + 0x02/0x09   → live view
                         ├─ 0x02/0xE1 05 + 0x02/0x01 → 拍照
                         ├─ 0x00/0x26 + 0x00/0x27    → 媒体列表
                         └─ HTTP /v2?storage=&path=  → 下载 JPEG
```

## 快速开始

1. 安装 Python 3.10+ 和 ffmpeg（`ffmpeg -version` 能跑通即可；也可设 `NANOTEST_FFMPEG` 指向 exe）。
2. 安装依赖：

   ```bat
   pip install -r requirements.txt
   ```

3. 双击 `run.bat`，或：

   ```bat
   python run.py
   ```

4. 没有相机时先看界面：`run.bat --mock`（本机假相机，不需要任何硬件）。

## 三种连接方式

### A. BLE 配对 → 自动加入相机热点（完整功能）

1. 相机开机、亮屏。
2. `Scan BLE` → 选中设备 → `Pair + join Wi-Fi`。
3. 首次配对相机会在屏幕上问，**去相机上点允许**；程序会自动 ACK 审批请求。
4. 读到 SSID/密码后自动加入热点，连 datalink，开流。

> 加入相机热点后电脑会**断网**（SoftAP 没外网）。要恢复请切回原来的 Wi-Fi。

### B. 手动 SSID/密码（BLE 不可用时）

相机屏幕的 Wi-Fi 设置里能读到 SSID 和密码，填进顶部输入框 → `Join + connect`。
已经在相机热点上时，直接 `Connect now`。

### C. 只用蓝牙（BLE only，不切网络）

`Scan BLE` → 选中 → **`BLE only`**。这条路径完全不碰 Wi-Fi，电脑保持联网。

**能做：**

- 读状态：电量/充电/底座、模式、录制状态、ISO、快门、EV、白平衡、存储、时间码
- 切拍摄模式（Video / Photo）
- **按快门拍照**（照片写在相机存储卡里）

**不能做：**

- 实时画面 —— 视频协议上只走 UDP 9004（`pktType 0x02`），BLE 上没有视频通道
- 下载照片 —— 文件走 HTTP `/v2`（Wi-Fi），BLE 没有文件通道

真机实测（2026-10-18，`OsmoNano-0B56`）：

```
BLE 连接，MTU 517
2 秒内收到 47 条状态推送（00/99、02/80、0D/02 …），电量 91%（充电/底座）
0x02/E1 [05]  → 回 00，模式字节 1 → 5（Photo）
0x02/01 [01]  → 回 00  ← 快门确认
00/99 推送持续约 80 帧/秒
```

带宽账也算得清：720p25 的 AVC 预览约 4 Mbit/s；BLE 5 在 517 字节 MTU 下的实际上限约 1 Mbit/s 量级，
而且协议里根本没有把视频塞进 BLE 的封装。所以 live view 只能走 Wi-Fi。

### 为什么没看到“配对请求”也能控制？

这里的“配对”是 **应用层 PIN 交换**（`0x07/0x45`），不是蓝牙绑定：

- GATT 控制通道不校验它 —— 实测未配对（`00 02`）状态下，相机自己的状态字节 `0x02/0x80 @57` 仍然从 1 变成 5，
  快门也回 `00`；
- PIN 只用来解锁 **Wi-Fi 凭据**（`0x07/0x07` / `0x07/0x0E`），所以“配对弹窗”通常只在相机亮屏、App 真正去要密码时才出现；
- 相机息屏/待机时还**不会画**这个弹窗。

### 待机陷阱（实测踩到过）

相机息屏后，BLE 仍连着、状态还在推，但命令会 **ACK `00` 却不执行**（模式不变、快门回 `D9`）。
必须先唤醒：

```
0x00/0x2B [04 00]      session wake
0x53/0x10              wake，相机回 01 00 00 00
```

程序在连接时和每次拍照前都会发这两条，然后才发 `0xE1` / `0x02/0x01`。

## 界面

| 控件 | 说明 |
| --- | --- |
| Scan BLE | 扫 DJI 设备（服务 FFF0 / 厂商 ID 08AA / 名称含 osmo、nano…） |
| Pair + join Wi-Fi | 完整配对 + 取凭据 + 加入热点 |
| **BLE only** | 只走 GATT：状态 + 模式 + 快门，不动 Wi-Fi |
| SSID / Pass / Join + connect | 手动加入相机热点 |
| Connect now | 已经连在相机热点上时直接建 datalink |
| auto live | 连接成功后是否自动开流；**取消勾选**可测试“只连不推流、只拍照” |
| Live ON / OFF / Re-enable (IDR) | 开流 / 停解码 + gate stop / 画面卡住时请求关键帧（别连点） |
| PHOTO | Wi-Fi 模式：切 Photo → 快门 → 轮询媒体列表 → 下载 JPEG 到 `captures/`；BLE 模式：只发快门 |
| Media list / Open captures | 拉最新一页媒体 / 打开下载目录 |
| CAMERA STATUS | 19 项状态，Wi-Fi 与 BLE 两种模式共用 |
| LINK | 实测 fps、视频包数、丢帧、解码错误、媒体条数；BLE 模式显示 BLE 链路信息 |

## 验证状态

| 环节 | 状态 |
| --- | --- |
| 协议字节（DUML/CRC/握手/ACK/命令） | ✅ 单元测试 + 与 Swift 参考实现抓包字节对齐（配对帧 51B、订阅 29/30/38B、初始窗口 +8） |
| 完整 Wi-Fi 链路（握手→状态→画面→拍照→下载→列表） | ✅ 本机 mock 端到端（25 fps、0 丢帧、JPEG 276 KB） |
| “从不开流只拍照” | ✅ mock 端到端（视频包数恒为 0） |
| BLE 扫描 | ✅ 真机：`OsmoNano-0B56`，model `0x0019`，RSSI −46 |
| BLE GATT 连接 / 唤醒 / SetPairingPIN | ✅ 真机：回 `07/45 = 00 02`（等屏幕确认），推 `07/46` 审批请求，ACK 已发 |
| **BLE-only：状态 + 模式 + 快门** | ✅ 真机：47 条状态/2s、模式 1→5、快门回 `00` |
| BLE 配对完成 / 取 SSID 密码 | ✅ 真机：相机屏幕点允许后 `07/45 = 00 01`，读到 SSID 与 12 位密码 |
| 相机 SoftAP / 真实 live view | ✅ 真机：8 s 解出 **233 帧，约 29–30 fps，2516 包，0 丢帧**（1280×720） |
| 真实拍照 + HTTP 下载 | ✅ 真机：快门 `00` → 媒体列表 → 下载 **3712×2088 JPEG（约 1 MB）** |

## 真机踩到的三个坑（都已修）

1. **Windows UDP 接收缓冲太小。** 开流瞬间相机会把 ~95 KB 的 IDR 一次性打过来，默认 64 KB 的 `SO_RCVBUF`
   会丢掉开头一两个包 → SPS/PPS 缺失 → 画面全黑、日志狂刷 `non-existing PPS 0 referenced`。
   现在绑定后立刻把接收缓冲抬到 4 MB，并在 3 s 没画面时补发一次 enable。
2. **ffmpeg 管道参数会吞帧。** `-fflags nobuffer -flags low_delay` 在 `pipe:0` 上把同一段码流从 214 帧
   压到 2 帧；去掉后正常，只保留 `-probesize 65536 -analyzeduration 0 -threads 1`。
3. **私有 SEI 不能按起始码扫描。** Nano 的 `06 F0 19` 后面 25 字节元数据里**故意**有未转义的 `00 00 01`，
   任何“清洗 NAL”的实现都会在这里切错。现在原样把访问单元喂给 ffmpeg，由它自己按长度跳过。

真机实测（`hw_frame.png` 是实拍帧，`captures/DJI_2026..._D.JPG` 是下载的静帧）：

```
live: frames=233 fps≈29-30 packets=2516 dropped=0
still: 3712x2088 JPEG, 974848 bytes
```

## 已知限制

- 预览流**固定 720p25**，没有命令能改分辨率/码率/帧率；4K 只存在于录制文件。
- 相机没有“停止推流”命令：Live OFF 只是停解码并给 Nano 发 gate stop，编码器可能还在跑。
- **单客户端**：相机只往一个 UDP 5 元组单播，不能两个程序同时看。
- `0x02/0xE1` 是稀疏枚举，**不要**发未知模式值（有把 Nano 冻死、需要扣电池的记录）；本程序只发 `0x00/0x01/0x05`。
- BLE 控制要求相机处于唤醒状态；息屏待机时命令会被 ACK 但不执行（程序已自动发唤醒序列）。
- BLE-only 拍的照片留在相机里；要取图仍需 Wi-Fi 或读卡器。
- 照片默认 JPEG；相机若设成 RAW，下载到的是 DNG。
- `netsh` 建的是 WPA2-PSK 配置；相机热点若是 WPA3 需要改 `nanotest/wifi.py`。

## 首次实机检查（建议顺序）

1. `python run.py` → `Scan BLE` 能否看到相机。
2. **`BLE only`** → 状态是否跳动、`PHOTO` 是否回 `00`（这条不碰网络，最安全）。
3. 配对：`Pair + join Wi-Fi` → 相机屏幕点允许 → 日志出现 `credentials from BLE: <SSID>`。
4. Wi-Fi：日志 `associated, local IP 192.168.2.x`。
5. datalink：日志 `handshake ACK` + `initial command window 0x....`。卡在这里说明 UDP 9004 不通。
6. `Live ON` → 3 秒内出画面。
7. `PHOTO` → `mode confirmed`、`shutter reply 00`、`newest still`、`saved`。

失败时把日志窗口内容发出来即可——日志带 opcode、payload 和错误。

## 目录

```
NanoTest/
  run.py / run.bat      入口
  requirements.txt      bleak + pillow
  nanotest/
    duml.py             DUML 帧 + CRC8/CRC16
    transport.py        8B transport / 12B routing / 握手 / 窗口 ACK
    commands.py         命令字节（Nano 的 0x41、gate、Photo 0x05）
    status.py           状态解析
    video.py            分片重组 + ffmpeg 解码
    media.py            媒体列表解析 + HTTP 下载
    datalink.py         UDP 9004：握手、1 Hz 注册、40 Hz ACK
    ble.py              bleak：扫描 / 连接 / 配对 / 取 SSID
    ble_session.py      只用 BLE：状态 + 模式 + 快门
    wifi.py             netsh 加入热点 + 本地 IP 探测
    session.py          Wi-Fi 业务流程
    mock.py             假相机（H.264 测试画面 + HTTP）
    app.py              tkinter 界面
  tools/
    selftest.py             无界面 Wi-Fi 全链路（mock）
    selftest_photo_only.py  不开流只拍照（mock）
    selftest_ble.py         真机 BLE-only 全流程
    hw_creds.py             配对后取 SSID/密码（写入 hw_creds.txt）
    hw_full.py              真机 Wi-Fi 全链路：画面 + 拍照 + 下载（带看门狗）
    hw_capture.py           抓 8 s 真机码流到 hw_capture.bin
    analyze_capture.py      离线看图片/NAL 结构
    replay_capture.py       离线复播并统计解码帧数
    test_decode.py          对比解码参数（验证 2/214 那个坑）
    verify_ble_control.py   BLE 控制 + 存储变化的独立验证
    diag_ble.py             BLE 命令逐条诊断
    wake_then_set.py        唤醒后切模式的最小复现
    ble_probe.py            真机 BLE 带宽/控制路由探针（默认只读）
    wifi_watchdog.py        切网看门狗
    blescan.py              只扫描
    envcheck.py             环境自检
    measure_live.py         帧率/丢帧测量
  tests/test_wire.py    协议单元测试
```

## 自测

```bat
python -m unittest discover -s tests -v
python tools\selftest.py
python tools\selftest_photo_only.py
python tools\envcheck.py
```

真机（需要相机在身边）：

```bat
python tools\blescan.py          :: 扫描
python tools\hw_creds.py         :: 配对后取 SSID/密码
python tools\selftest_ble.py     :: BLE-only：状态 + Photo + 快门
python tools\hw_full.py          :: 切到相机热点，画面 + 拍照 + 下载，自动切回
python tools\ble_probe.py        :: BLE 带宽与控制路由（只读）
```

> `hw_full.py` / `hw_capture.py` 会把电脑 Wi-Fi 切到相机热点约 30–60 秒，并在结束时切回原来的网络；
> 同时会拉起一个 150 秒的看门狗，主脚本异常退出也会把网络恢复。运行前请确认可以短暂断网。

## 协议参考

- 实时流：`pktType 0x02`，1280×720，~25 fps，AVC High（`avc1.64001f`），16 字节 DJI 头（`00 00 01 FF` + 长度 + 8B 元数据），大图跨 63 包分组
- 开流：`0x02/0x09` payload `00×10 03` → `0x09/0xA8` payload `00 04 02 …`，receiver `0x41`
- 拍照：`0x02/0xE1` `[05]` → `0x02/0x01` `[01]`；照片在 `DCIM/DJI_001/*.JPG`
- 取图：`0x00/0x26`（cursor 1=SD，0x40000001=内置）→ `0x00/0x27` 分片 → `GET http://192.168.2.1/v2?storage=&path=`
- 保活：`0x00/0x88` + `0x00/0x81` 每 1 s（Wi-Fi）；`0x00/0x2B [01 01]` 每 1 s（BLE）
- 窗口 ACK：`pktType 0x04` 每 25 ms；首个命令序列取相机 34 字节遥测的 `bytes[8..9] + 8`
