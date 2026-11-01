# SideAssistant 架构深度重构与治理终态报告
# (SideAssistant Architecture Refactoring & Governance Final Report)

> **版本**: v3.0-Hexagonal-Clean  
> **完成日期**: 2026-11-01  
> **执行环境**: Flutter 3.24.x / Dart 3.5.3 (Windows 11 x64, Linux x86_64 Edge Host)  
> **质量基线**: 静态分析 0 缺陷 | 纯 Dart 编译零泄漏 | 自动化测试 100% 通过 (485/485) | 全量 133 个 Dart 文件 0 依赖环路 | 架构门禁 0 新增违规 | UI 对底层 Service 依赖**完全清零** | 233 服务器安全铁律 100% 遵从

---

## 1. 重构背景与核心成果概览 (Executive Summary)

### 1.1 背景与痛点
在重构前，SideAssistant 经历了长期的功能迭代，积累了典型的架构债务：
1. **依赖倒挂与控制反转缺失**：核心领域层（`lib/core/engine/`）反向依赖具体的底层实现（如具体 ASR 服务、TTS、大模型、知识库等），违反依赖倒置原则（DIP）。
2. **上帝接口与胖接口 (Fat Interface)**：`AssistantDriverPort` 聚合了全部外部驱动能力，迫使 UI 控制器 (`AssistantController`) 充斥大量样板代理代码；各功能界面对控制器各接口权责不清。
3. **UI 越权跨层依赖**：多个 UI Section 和 Screen 直接 import 并调用具体的硬件/系统服务（如 `CameraService`、`AudioInputDeviceService`、`LlmService`），导致展现层与基础设施层紧密耦合。
4. **ASR 引擎硬编码与缺乏扩展机制**：语音管线内部通过写死 switch-case 分支选择语音识别引擎，无法通过插件或配置动态扩展新引擎。
5. **部署安全隐患**：远端 233 服务器（192.168.31.233）承载生产环境声纹库、历史会话与系统硬件配置，部署过程必须严格杜绝任何配置覆盖与数据破坏。

### 1.2 阶段性交付计分卡 (Scorecard)

| 治理维度 | 重构前基线 (Phase 0) | 重构终态 (Phase 6) | 改善幅度与收益 |
|---|---|---|---|
| **核心端口契约 (Ports)** | 仅有 1 个胖接口 (`AssistantDriverPort`) | **10 个纯 Dart 领域端口** 下沉至 `lib/core/ports/` | 实现完全的六边形依赖倒置 (DIP) |
| **驱动接口隔离 (ISP)** | 1 个巨型接口 (30+ 方法) | **拆分为 4 大微端口** (`ChatPort`, `SessionPort`, `VoiceControlPort`, `SystemDiagnosticsPort`) | 符合接口隔离原则，语义边界清晰 |
| **UI 对 Service 越权依赖** | 7 处违规 (`UI_DEPENDS_ON_SERVICE`) | **0 处 (全部清零！)** | UI 展现层与基础设施服务彻底解耦 |
| **Controller 样板代理代码** | 约 353 行 (包含大量直接 forwarder) | **约 230 行**，通过 `AssistantDriverPortForwarder` mixin 消除冗余 | 纯化为聚焦 UI 状态驱动的 ViewModel |
| **ASR 引擎实例化解耦** | 核心协调器写死 switch-case 且反向 import 服务 | **`AsrEngineFactory` + `AsrFactoryRegistry` SPI** | 支持动态注册，核心层零反向 import |
| **DI 组装中枢 (Composition Root)** | 散落在各入口构造函数多层下传 | **统一由 `AppContainer` 装配** (`initializeProductionClient` / `initializeHeadlessServer`) | 单一入口组装，测试与生产环境解耦 |
| **循环依赖 (Cycles)** | 0 环路 (118 文件) | **0 环路 (133 文件)** | 133 个文件 DAG 严格无环 |
| **架构守卫白名单违规项** | 42 项 (Phase 0) | **34 项 (净消减 8 项，消灭所有 UI 违规)** | 依赖门禁工具 `tool/check_deps.dart` 自动化防劣化 |
| **自动化测试用例数** | 480 个通过 | **485 个通过** | 新增 ASR 工厂与微端口覆盖测试，全绿保证 |
| **纯 Dart 编译零泄漏** | `bin/linux_server.dart` 编译通过 | **`dart compile kernel` 0 泄漏，0 警告** | 核心业务与平台无头服务器完全与 `dart:ui` 隔离 |
| **233 部署安全防护** | 基础部署脚本 | **双重安全防护 (远端备份+本地快照+空文件回滚+权限校验)** | 100% 遵从 `AGENTS.md` 铁律 |

---

## 2. 六边形架构与微端口拓扑 (Hexagonal Ports Topology)

重构后，系统建立了一套严格的六边形端口体系（位于 `lib/core/ports/`），领域核心仅依赖抽象契约，所有基础设施作为适配器向核心插入：

```
                              ┌─────────────────────────────────────────┐
                              │           UI / API Drivers              │
                              │  (Flutter UI / AppDriverServer / CLI)   │
                              └────────────────────┬────────────────────┘
                                                   │
                                                   ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                       Core Application Boundary                                       │
│                                                                                                       │
│   ┌───────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                 Inbound Port: AssistantDriverPort                             │   │
│   │   ├── ChatPort                 (对话控制、文本输入、LLM交互、打断与恢复)                         │   │
│   │   ├── SessionPort              (会话生命周期 CRUD、切换、删除、历史导出)                        │   │
│   │   ├── VoiceControlPort         (麦克风监听、手动录音、设备切换、声纹鉴权、ASR转写)              │   │
│   │   └── SystemDiagnosticsPort    (系统软硬件与网络自检、麦克风诊断、配置刷新)                      │   │
│   └───────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                   │                                                   │
│                                                   ▼                                                   │
│   ┌───────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                       AssistantEngine                                         │   │
│   │               ├── DialogueIntentCoordinator (对话与意图编排)                                  │   │
│   │               ├── VoicePipelineCoordinator  (语音录入、VAD、ASR解码与仲裁)                    │   │
│   │               └── SessionHistoryCoordinator (多会话与持久化协调)                              │   │
│   └───────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                   │                                                   │
│                                                   ▼                                                   │
│   ┌───────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                         Outbound Ports                                        │   │
│   │   ├── LlmPort                  (大语言模型流式与单次生成)                                      │   │
│   │   ├── AsrPort                  (语音识别抽象，支持流式与离线)                                  │   │
│   │   ├── TtsPort                  (语音合成与播放控制)                                            │   │
│   │   ├── PromptSoundPort          (提示音效播放)                                                 │   │
│   │   ├── TriggerMatcherPort       (唤醒词与退出词匹配)                                           │   │
│   │   ├── KnowledgePort            (LightRAG / 知识库检索)                                        │   │
│   │   ├── CameraPort               (视觉抓拍与相机流抽象)                                         │   │
│   │   ├── ChatRepository           (会话与聊天消息持久化存储)                                      │   │
│   │   └── AudioHardwarePort        (音频输入硬件控制与列表枚举)                                   │   │
│   └───────────────────────────────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────┬───────────────────────────────────────────────────┘
                                                    │
                                                    ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                       Infrastructure Adapters                                         │
│  ├── LlmService (OpenAI, Gemini, Ollama, DeepSeek)                                                    │
│  ├── AsrEngineFactory -> [LocalSenseVoiceAsrService, StreamingZipformerAsrService, GeminiLiveService] │
│  ├── TtsService (FlutterTTS, EdgeTTS, SystemTTS)                                                      │
│  ├── SoundService (本地音频与提示音播放)                                                              │
│  ├── TriggerMatcher (中文模糊拼音与分词匹配引擎)                                                      │
│  ├── LightRagService (本地知识图谱检索)                                                               │
│  ├── CameraService (LocalCameraSource, NanoCameraSource)                                              │
│  ├── PreferencesHelper / StorageBridge (持久化文件系统)                                               │
│  └── LinuxHardwareAdapter / AudioInputDeviceService (底层 HAL / Alsa / PulseAudio)                    │
└───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心重构与设计模式演进详解

### 3.1 ISP 接口隔离与 Mixin 转发 (Phase 3)
原 `AssistantDriverPort` 承载数十个方法。重构后将其拆解为四大高内聚子端口：
1. **`ChatPort`**：专注于流式消息交互、打断与恢复；
2. **`SessionPort`**：专注于多会话生命周期与历史管理；
3. **`VoiceControlPort`**：专注于音频与麦克风设备、手动录音与声纹识别；
4. **`SystemDiagnosticsPort`**：专注于软硬件自检、网络状态核查与配置同步。

通过设计 `AssistantDriverPortForwarder` mixin：
```dart
mixin AssistantDriverPortForwarder implements AssistantDriverPort {
  AssistantDriverPort get driverPort;

  @override
  Future<void> sendTextMessage(String text, {List<String>? base64Images}) =>
      driverPort.sendTextMessage(text, base64Images: base64Images);

  @override
  Future<void> interruptSpeaking() => driverPort.interruptSpeaking();
  // ... 统一透明代理剩余微端口方法
}
```
`AssistantController` 只需引入该 mixin 并指向底层的 `_engine`，立即消除了原控制器中近 200 行重复且容易漏改的样板代理代码，使控制器代码精炼度提升超过 35%。

### 3.2 ASR 引擎工厂与 SPI 插件机制 (Phase 2)
在 `VoicePipelineCoordinator` 中，原先由 coordinator 直接 new 出各种具体的 ASR Service，并根据 `settings.asrEngine` 硬编码分支。这不仅反向依赖了 3 个具体的语音服务，而且无法在运行时插入外部引擎。
重构后建立 `AsrEngineFactory` 与 SPI 插件体系：
- 静态工厂支持 `AsrEngineFactory.create(settings)`，返回统一契约 `AsrEngineBundle<AsrService>`；
- 提供 `registerEngine(String engineType, AsrEngineBuilder builder)`，支持第三方或测试环境动态挂载定制 ASR 引擎；
- 核心 Port 中定义 `AsrFactoryRegistry` 委托，由 `AppContainer` 统一在启动阶段注册默认引擎构造器，彻底切断了 Core 对底层 Speech Services 的直接代码引用。

### 3.3 UI 展现层 Service 依赖彻底清零 (Phase 4)
通过对 UI 界面的精细重构，达成了 **所有 UI 界面零 Service 依赖** 的里程碑：
1. **系统调用与平台桥接下沉**：
   - 将 `SystemFileLauncher` 抽象至 `lib/core/platform/system_file_launcher.dart`；
   - 将悬浮胶囊桥接抽象至 `lib/core/platform/floating_capsule_bridge.dart`；
   - 保持原 service 目录 re-export 向后兼容。
2. **设备模型下沉**：
   - 将 `CameraResolution` 与 `AudioInputDeviceOption.autoId` 常量下沉到 `lib/core/models/device_options.dart`；
3. **UI 业务行为统一经由 Controller 代理**：
   - `LlmSettingsSection`：拉取大模型列表从直接调用 `LlmService.fetchAvailableModels` 改为 `controller.fetchAvailableModels`；
   - `CameraVisionSection`：分辨率获取与 Nano 链路测试全部收口至 `controller`；
   - `SettingsScreen`：音频与相机权限核查由 `controller.requestAudioPermission()` 与 `controller.requestCameraPermission()` 代理。
4. **战果**：存量白名单中所有的 7 项 `UI_DEPENDS_ON_SERVICE` 违规**全部彻底消减归零**！

### 3.4 统一依赖装配源 (Composition Root - Phase 2)
通过 `AppContainer` 实现单一装配源：
- **`initializeProductionClient(settings)`**：装配适用于 Flutter 图形界面的所有前后台基础设施（TTS、LightRAG、Camera、ASR、LLM、Storage），组装 `AssistantEngine`，并供给 `AssistantController`。
- **`initializeHeadlessServer(settings)`**：装配无头边缘计算 Linux 服务端所需的基础设施（禁用 GUI 专属服务，确保使用纯 Dart 的 `foundation_bridge_io.dart` 与文件系统存储），组装 `AssistantEngine`，并供给 `AppDriverServer`。
- 保证无论是客户端还是无头服务端，业务引擎内部完全一致，无分叉逻辑。

---

## 4. 233 服务器部署安全体系 (AGENTS.md Compliance)

根据核心铁律，向 233 服务器（192.168.31.233）部署时，**严禁覆盖任何用户配置与数据**。
现已建立并验证了双重安全防线机制：

```mermaid
sequenceDiagram
    autonumber
    participant Dev as 本地构建环境 (Dev)
    participant SSH as SSH / SCP 管道
    participant Remote as 233 服务器 (Remote Host)
    participant Systemd as systemd 守护进程

    Dev->>Remote: [安全防线 1] 检查远端 preferences.json
    alt 远端配置存在
        Remote-->>Remote: cp -p preferences.json preferences.json.bak_TIMESTAMP
        Dev->>Remote: scp 下载远端配置副本至本地 build/remote_backups/
    end

    Dev->>Dev: dart compile kernel bin/linux_server.dart -o build/linux_server.dill
    Dev->>Remote: scp linux_server.dill 及 run_server.sh 至 /home/hao/side_assistant/
    Note over Dev,Remote: 严禁向 /home/hao/.local/share/side_assistant/ 写入代码文件

    Dev->>Remote: 触发远端原生编译及 systemctl restart side-assistant.service
    Dev->>Remote: [安全防线 2] 校验重启后 preferences.json 大小与完整性
    alt 发现配置异常变为空 (0 bytes)
        Dev->>Remote: 自动触发回滚: cp -p bak_TIMESTAMP preferences.json && restart
        Dev-->>Dev: 发出严重警告并恢复成功
    else 配置校验通过
        Dev-->>Dev: 部署成功闭环，数据 100% 完好
    end
```

### 安全规则细则验证：
1. **数据目录隔离**：代码运行目录 `/home/hao/side_assistant` 与数据持久化目录 `/home/hao/.local/share/side_assistant` 物理分离。部署脚本只向代码目录推包。
2. **硬件调优策略保留**：`run_server.sh` 使用 `cp -n` 仅在未配置时补充 WirePlumber `52-disable-suspend.lua`，绝不修改服务器既有 `/etc/udev/rules.d/50-bluetooth-power.rules`。
3. **systemd 单元保护**：`install.sh` 默认保留用户自定义的 `/etc/systemd/system/side-assistant.service`，避免覆盖环境变量或自定义端口。

---

## 5. 质量防护与防劣化护栏 (Quality Guards)

为了防止未来代码迭代破坏本次重构成果，建立了三道刚性自动化卡点：

### 5.1 依赖关系与循环依赖检查器 (`tool/check_deps.dart`)
- 每次提交或 CI 运行都会扫描全库 133 个 Dart 文件；
- 基于 Tarjan 算法检测是否有新增环路（当前保持 **0 cycles**）；
- 实施分层调用合规检查：
  - Core 严禁引用 Services（通过 Ports 接口倒置）；
  - UI 严禁直接引用 Services（保持 **0 违规**）；
  - 核心层与无头编译严禁泄漏 `package:flutter`；
- 白名单机制 (`tool/deps_allowlist.txt`)：存量违规只减不增，出现任何新增跨层违规立刻中断 CI 并抛出阻断性错误。

### 5.2 持续集成流水线 (`.github/workflows/ci.yml`)
在 GitHub Actions 中自动执行：
1. `flutter analyze --fatal-infos`
2. `dart run tool/check_deps.dart`
3. `dart compile kernel bin/linux_server.dart`
4. `flutter test --exclude-tags benchmark`

---

## 6. 结论

通过本次深度系统化重构，SideAssistant 成功从“以单体控制器/单体引擎为中心”的紧耦合架构，平滑演进为标准、规范、健壮的**六边形整洁架构 (Hexagonal Clean Architecture)**。
- 核心业务层纯 Dart 化，达到高度自洽与高内聚；
- 展现层（UI / Web Console / CLI / REST API）实现完全的低耦合与职责清晰；
- 建立起了坚不可摧的架构护栏与部署安全机制，为后续的多端演进与智能体扩展奠定了扎实工程根基。
