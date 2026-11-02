# SideAssistant 研发与部署规范 (AGENTS.md)

## 🚨 核心部署铁律（最高优先级）

**部署到 233 服务器（192.168.31.233）时，永远不要覆盖 233 上原有的任何配置和数据！！！**

### 细则要求：
1. **严禁覆盖用户配置与数据**：
   - 远端数据目录 `/home/hao/.local/share/side_assistant/` 下的所有文件（包括但不限于 `preferences.json`、`support/`、会话历史、声纹样本、自定义模型设置、API Key 等）绝对不可覆盖或重置。
   - 绝不允许将本地的测试配置、空的声纹库或默认参数覆盖到 233。

2. **部署脚本行为准则**：
   - 部署脚本（如 `deploy_to_server.ps1`、`linux_server/deploy_to_server.ps1`）仅允许更新编译后的原生可执行程序/内核文件（`linux_server.dill` / `side_assistant_server`）、公共脚本（`run_server.sh`）及基础模型资产。
   - 严禁在部署过程中执行无保留的数据清理、目录重置或无提示覆盖。

3. **保留系统级硬件配置**：
   - 严禁重置或覆盖 233 上已生效的硬件适配与电源调优策略（例如蓝牙 USB 防休眠 udev 规则 `/etc/udev/rules.d/50-bluetooth-power.rules`、WirePlumber 配置等）。

## 🖥️ Web 控制台与配置门面：只改源文件，生成物自动构建

### 1. Web 控制台（`web_console/` 模块化源文件 → `web_console_html.dart`）
- 源文件模块化（按需编辑对应小文件，单个文件均小巧易读，告别单文件突破 800 行窗口）：
  - `web_console/css/`：按页面区域细分的 6 个样式子模块（`01_theme.css`、`02_layout.css`、`03_chat.css`、`04_drawer.css`、`05_settings.css`、`06_components.css`，均 < 200 行）
  - `web_console/js/`：按业务职责细分的 8 个脚本子模块（`01_state.js`、`02_sse.js`、`03_chat.js`、`04_mic_test.js`、`05_volume.js`、`06_actions.js`、`07_drawer.js`、`08_settings.js`）
  - `web_console/body.html`：页面 DOM 骨架结构（抽屉、消息流、音量弹窗、设置面板、模态框）
  - `web_console/index.html`：极简主 HTML 模板骨架（插槽占位）
- 生成物（只读常量）：`lib/services/automation/web_console_html.dart`（首行标注 `GENERATED CODE - DO NOT MODIFY BY HAND`）
- 手动构建命令：`dart run tool/build_web_console.dart`（运行 `agent_check.dart` 时会自动检测同步）

### 2. 领域配置门面（`domain_configs.dart` → `app_settings.g.dart`）
- 源文件（唯一编辑入口）：`lib/core/models/domain_configs.dart` 中的 5 大领域类（`AudioConfig`、`LlmConfig`、`TtsConfig`、`VisionConfig`、`ServerConfig`）
- 生成物（自动派生门面）：`lib/core/models/app_settings.g.dart`（自动生成扁平属性代理、构造器、序列化与增量更新，**禁止手改**）
- 构建命令：`dart run tool/build_settings.dart`（运行 `agent_check.dart` 或 `check_deps.dart` 时会自动检测与校验同步）
- **根治霰弹式修改**：所有领域类均继承 `DomainConfig` 基类，深度 `==` 与 `hashCode` 全自动生成；新增字段无需修改 `app_settings.dart`，一键生成门面。

## ✍️ 代码编辑与检索规范（避免无谓返工）

1. **行尾统一 LF**：仓库由 `.gitattributes` 固定 `* text=auto eol=lf`，本机不要再用 `core.autocrlf=true`。改动前若发现文件是 CRLF，先整文件转 LF 再编辑——否则「精确文本替换」会因不可见差异反复失败。
2. **不要用临时脚本改代码**：禁止为了绕过编辑失败而新建 `tool/update_*.dart`、`node -e "...regex..."` 之类的脚本再删掉。连续两次替换失败时应重新读取目标片段、按行号定位后重试，而不是改写工具链。
3. **检索优先 `rg`**；用 `git grep` 时注意它默认只搜「已跟踪」文件，搜索前确认文件已 `git add`，或显式加 `--no-index`。
4. **不要在含大量无关改动的仓库里跑无参数的 `git status` / 全仓库 `git grep`**：先用 `git status --porcelain <路径>`、`git grep ... -- <路径>` 限定范围，避免把几百 KB 噪声读进上下文。
5. **配置字段增改规范（告别霰弹式修改）**：改配置仅需同步 `AppConstants` → `domain_configs.dart`（在领域类中声明字段/构造/copyWith/fromMap/toMap，`DomainConfig` 自动提供深度 `==` 与 `hashCode`）→ 运行 `dart run tool/agent_check.dart`（自动构建同步 `app_settings.g.dart` 门面）→ 使用方服务 → Flutter 设置界面 → Web 控制台。
6. **文件规模控制 (<800行)**：尽量控制单个源码文件在 800 行以内（AI Agent 工具单步阅读上限）。超大单体类应抽取 support 辅助类或子组件，防止 AI 编辑截断或上下文丢失。
7. **提交前必须格式化**：改动后运行 `dart format lib test tool bin`；CI 与 `tool/agent_check.dart` 的「格式化门禁」都会拦截未格式化代码。

## 🤖 AI Coding Agent 一键自检中枢 (Fast Feedback Loop)

为避免单次测试输出 300KB+ 日志挤占 Token 上下文，以及避免混淆 `dart test` 与 `flutter test`，请统一使用项目专用的自检中枢：

| 场景 | 命令 | 预期耗时 | 说明 |
| --- | --- | --- | --- |
| **日常极速自验 (推荐)** | `dart run tool/agent_check.dart` | **< 10 秒** | 一键跑完架构守卫、Web控制台同步、静态分析、Linux内核编译及核心契约单测 |
| **Agent 友好度体检** | `dart run tool/agent_check.dart --audit` | **约 1 秒** | 检查超大文件(>800行)、CRLF换行污染、生成物同步及架构基线评分 |
| **靶向领域验收** | `dart run tool/agent_check.dart --scope <speech\|dialogue\|vision\|server\|config>` | 约 5-15 秒 | 靶向执行指定领域测试子集，加速模块级开发迭代 |
| **全量交付验收** | `dart run tool/agent_check.dart --full` | 约 50 秒 | 覆盖全量 500+ 个单元与对抗压力测试 |
| 仅检查分层依赖门禁 | `dart run tool/check_deps.dart` | 约 1 秒 | 检查循环依赖与分层违规，并校验 Web Console 是否同步 |
| 仅检查格式 | `dart format --output=none --set-exit-if-changed lib test tool bin` | 约 1 秒 | 确保全仓符合 dart format，CI 与 agent_check 均会拦截 |
| 仅跑静态代码分析 | `dart analyze --fatal-infos` | 约 3 秒 | 确保 0 errors, 0 warnings, 0 infos |
| 仅跑单模块测试 | `flutter test test/<目标测试文件>.dart` | 约 2-4 秒 | **切勿使用 `dart test`**（本项目测试依赖 Flutter 测试环境） |

## 🗺️ 架构分层速查地图 (Architecture Topology)

本项目采用严格的**六边形微端口架构**，修改代码请遵循以下单向依赖流：

```
[UI / Web Console / CLI Driver]
          │
          ▼ (调用 Inbound Ports)
[lib/core/ports/ (ChatPort, SessionPort, VoiceControlPort, SystemDiagnosticsPort)]
          │
          ▼ (实现 & 编排)
[lib/core/engine/ (AssistantEngine, Coordinators)]
          │
          ▼ (依赖 Outbound Ports 抽象契约: LlmPort, AsrPort, TtsPort, CameraPort...)
[lib/services/ (基础设施适配器: OpenAI, Gemini, Sherpa-ONNX, Linux HAL...)]
```

* **严禁反向依赖**：`lib/core/**` 绝不可反向 import `lib/services/**` 或 `lib/ui/**`（存量违规已实现 **0 违规**，`tool/deps_allowlist.txt` 实行 0 容忍门禁）。
* **纯 Dart 边缘隔离**：`lib/core/**` 与 `bin/linux_server.dart` 严禁 import `package:flutter` 或 `dart:ui`，保证 Linux 无头服务器可以纯 Dart 编译运行。

### 📋 领域与模块速查矩阵 (Domain Quick Reference Matrix)

| 功能域 (Domain) | Coordinator / Engine | Inbound / Outbound Ports | 核心 Service 适配器 | UI 展现 / 控制台 | 靶向单测集 (`--scope`) |
| --- | --- | --- | --- | --- | --- |
| **语音声学 (Speech)** | `VoicePipelineCoordinator` | `VoiceControlPort`<br>`AsrPort`, `TtsPort` | `AsrService` (Sherpa/Gemini)<br>`TtsService` (Edge/Sherpa)<br>`VoiceListeningService`<br>`SpeakerVerificationService` | `HomeScreen` (波形动效)<br>`SettingsScreen` (语音设置)<br>Web Console (音频交互) | `--scope speech`<br>(`voice_pipeline_coordinator_test`, `asr_*`, `vad_*`, `tts_*` 等 20 个套件) |
| **对话意图 (Dialogue)** | `DialogueIntentCoordinator`<br>`SessionCoordinator` | `ChatPort`, `SessionPort`<br>`LlmPort`, `ChatRepository` | `LlmService` (OpenAI/Gemini)<br>`ChatHistoryService`<br>`SessionManager`<br>`LightragService` | `HomeScreen` (消息气泡流)<br>`ChatHistoryDrawer`<br>Web Console (对话视窗) | `--scope dialogue`<br>(`dialogue_intent_*`, `assistant_engine_*`, `llm_*`, `chat_history_*` 等 18 个套件) |
| **视觉感知 (Vision)** | `AssistantEngine` (视觉抓拍分发) | `CameraPort` | `CameraService`<br>`CameraSourceRegistry`<br>`LinuxV4L2CaptureSource`<br>`NanoWifiCaptureSource` | `HomeScreen` (取景微缩图)<br>Web Console (抓拍诊断) | `--scope vision`<br>(`vision_intent_and_camera_test`, `camera_capture_source_spi_test`, `camera_service_stress_test`, `nano_camera_source_test`) |
| **边缘服务 (Server)** | `AssistantEngine` (驱动门面) | `AssistantDriverPort`<br>`SystemDiagnosticsPort` | `AppDriverServer`<br>`LinuxHardwareAdapter`<br>`HttpRouter` / 各 Handler | `web_console/index.html`<br>(REST API & SSE 流) | `--scope server`<br>(`server_transport_modular_test`, `http_server_transport_adversarial_test`, `linux_server_web_console_test`, `linux_hal_*`) |
| **系统配置 (Config)** | `AppContainer` (DI 服务定位) | 依赖注入 / 各领域配置契约 | `AppSettings`<br>`DomainConfigs`<br>`SystemFileLauncher` | `SettingsScreen`<br>Web Console 配置面板 | `--scope config`<br>(`config_domain_serialization_test`, `incremental_settings_update_test`, `service_locator_di_test`, `llm_model_dropdown_test`) |



