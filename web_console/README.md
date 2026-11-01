# Web Console 前端源码目录

本目录包含 SideAssistant Linux 无头服务器内嵌的 Web 管理与对话控制台前端源文件。

## 文件结构
* `index.html`: 自包含的 HTML / CSS / JavaScript 单页面源文件，具备现代前端编辑器语法高亮、代码提示与格式化支持。
* 样式与设计语言严格对齐客户端 `AppTheme`（青色主调、药丸按钮、暗色模式、移动端响应式布局）。

## 资产构建与同步
编辑 `index.html` 后，运行以下命令将其同步打包进 Dart 运行时资产：

```bash
dart run tool/build_web_console.dart
```

该命令会自动生成 `lib/services/automation/web_console_html.dart`，确保 Linux 无头服务端仍以单二进制/零外部静态资源依赖的方式运行。
