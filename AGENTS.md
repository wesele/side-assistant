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

## 🖥️ Web 控制台：只改源文件，生成物必须重新构建

Web 控制台有「源文件」和「内嵌生成物」两份，二者必须同步，**永远只手改源文件**：

| 角色 | 路径 | 可否手改 |
| --- | --- | --- |
| 源文件（唯一编辑入口） | `web_console/index.html` | ✅ 改这里 |
| 生成物（编译进 Dart 的常量） | `lib/services/automation/web_console_html.dart` | ❌ 禁止手改 |

- 生成器：`tool/build_web_console.dart`；生成物首行标注 `GENERATED CODE - DO NOT MODIFY BY HAND`，任何手改都会在下次构建时被整体覆盖。
- **改完 `web_console/index.html` 后必须执行**：

  ```powershell
  dart run tool/build_web_console.dart
  ```

- 提交前自检：`git diff --stat -- web_console/index.html lib/services/automation/web_console_html.dart`，两者应同时出现且规模相称；只有 html 变了而 `web_console_html.dart` 没变，说明忘了构建。
- Linux 服务器（233）上运行时读取的是生成物，漏构建会导致改动在 233 上不生效。

## ✍️ 代码编辑与检索规范（避免无谓返工）

1. **行尾统一 LF**：仓库由 `.gitattributes` 固定 `* text=auto eol=lf`，本机不要再用 `core.autocrlf=true`。改动前若发现文件是 CRLF，先整文件转 LF 再编辑——否则「精确文本替换」会因不可见差异反复失败。
2. **不要用临时脚本改代码**：禁止为了绕过编辑失败而新建 `tool/update_*.dart`、`node -e "...regex..."` 之类的脚本再删掉。连续两次替换失败时应重新读取目标片段、按行号定位后重试，而不是改写工具链。
3. **检索优先 `rg`**；用 `git grep` 时注意它默认只搜「已跟踪」文件，搜索前确认文件已 `git add`，或显式加 `--no-index`。
4. **不要在含大量无关改动的仓库里跑无参数的 `git status` / 全仓库 `git grep`**：先用 `git status --porcelain <路径>`、`git grep ... -- <路径>` 限定范围，避免把几百 KB 噪声读进上下文。
5. **一次只改一处、改完即验证**：改配置字段需同步 `AppConstants` → `domain_configs.dart`（字段/构造/copyWith/序列化/`==`/`hashCode`）→ `app_settings.dart` 门面 → 使用方服务 → Flutter 设置界面 → 上面的 Web 控制台。

