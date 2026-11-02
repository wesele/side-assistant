# SideAssistant

Flutter 跨平台(Windows / Android)+ 纯 Dart Linux 无头服务器的语音 AI 助手。采用六边形(端口-适配器)架构。

> 研发与部署铁律、架构分层、自检命令见 [AGENTS.md](AGENTS.md)。**部署到 233 服务器前必读。**

## 目录速览

| 路径 | 作用 |
| --- | --- |
| `lib/core/` | 纯 Dart 核心:`ports/`(契约)、`engine/`(AssistantEngine 与 Coordinators)、`models/`(配置与领域模型) |
| `lib/services/` | 基础设施适配器:`automation` `lightrag` `llm` `nlp` `speech` `storage` `vision` |
| `lib/ui/` | Flutter 界面(仅 UI 层可依赖 Flutter) |
| `bin/linux_server.dart` | Linux 无头服务器入口(纯 Dart) |
| `web_console/` | Web 控制台**前端源码**:改 `js/*.js`、`css/*.css`、`body.html`;`index.html` 仅模板骨架。生成物 `lib/services/automation/web_console_html.dart` 禁止手改 |
| `linux_server/` | 233 服务器部署与运行脚本 |
| `tool/` | 自检、依赖门禁、Web 控制台构建与各类探测脚本 |
| `test/` | 单元 / 契约 / 对抗压力测试(用 `flutter test`,不要用 `dart test`) |
| `NanoTest/` | DJI Osmo Nano 逆向用 Python 子项目,与主工程无代码依赖 |
| `docs/` | `reports/` 研究与交付报告 |

## 常用命令

```powershell
dart run tool/agent_check.dart          # 日常极速自检 (<10s)
dart run tool/agent_check.dart --full   # 全量验收
dart run tool/build_web_console.dart    # 改完 web_console/js|css|body.html 后必跑
flutter test test/<file>.dart           # 单个测试
```

## 编码约定

- 源码与文档一律 UTF-8(无 BOM)、LF 行尾。
- `lib/core/**` 不得 import `lib/services/**`、`lib/ui/**`、`package:flutter`。
