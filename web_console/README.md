# Web Console 前端源码目录

本目录包含 SideAssistant Linux 无头服务器内嵌的 Web 管理与对话控制台前端源文件。

**唯一事实来源就是本目录的 `css/`、`js/`、`body.html` 与 `index.html`。** 历史上曾存在的单体副本 `styles.css` / `app.js` 已删除，请勿再创建。

## 文件结构

```
web_console/
├── index.html          模板骨架（307 字节，仅含 3 个插槽标记）
├── body.html           页面 DOM 结构（抽屉 / 消息流 / 麦克风面板 / 音量弹窗 / 设置页）
├── css/                6 个样式模块（按文件名排序拼接）
│   ├── 01_theme.css        配色变量，对齐 lib/ui/theme/app_theme.dart
│   ├── 02_layout.css       顶部 AppBar 与页面骨架
│   ├── 03_chat.css         聊天消息列表与空白态
│   ├── 04_drawer.css       左侧抽屉 ChatHistoryDrawer
│   ├── 05_settings.css     SettingsScreen 样式
│   └── 06_components.css   麦克风测试与音量可视化面板
└── js/                 8 个脚本模块（按文件名排序拼接）
    ├── 01_state.js         全局状态与密码
    ├── 02_sse.js           SSE 连接与实时状态渲染
    ├── 03_chat.js          消息列表渲染（renderMarkdown / _buildMessageBubble）
    ├── 04_mic_test.js      麦克风实时测试面板
    ├── 05_volume.js        服务器音量控制
    ├── 06_actions.js       聊天交互与快捷操作
    ├── 07_drawer.js        左侧历史抽屉逻辑
    └── 08_settings.js      设置页逻辑
```

`index.html` 只是模板骨架，含三个插槽标记：`/* {{STYLES}} */`、`<!-- {{BODY}} -->`、`// {{APP}}`。构建时分别被 `css/*.css`、`body.html`、`js/*.js` 的拼接结果替换。**不要往 `index.html` 里写业务代码。**

## 资产构建与同步

编辑 `css/`、`js/`、`body.html` 任一文件后，必须运行：

```bash
dart run tool/build_web_console.dart
```

该命令把上述模块组装成单文件自包含 HTML，写入 `lib/services/automation/web_console_html.dart`（Linux 无头服务端零外部静态资源依赖）。

**禁止手改 `lib/services/automation/web_console_html.dart`**：它是生成物，下次构建会被覆盖；`dart run tool/check_deps.dart` 会校验源文件与生成物是否同步，不同步直接阻断。
