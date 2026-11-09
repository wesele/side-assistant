// GENERATED CODE - DO NOT MODIFY BY HAND
// Source: web_console/ (index.html, body.html, css/*.css, js/*.js)
// To rebuild: dart run tool/build_web_console.dart

/// Linux 服务器版 Web 管理与对话控制台（单文件自包含 HTML/CSS/JS，零外部 CDN 依赖）
/// 界面视觉与交互全面对齐 Windows / Android 客户端 (AppTheme / HomeScreen / ChatHistoryDrawer / SettingsScreen)
String buildWebConsoleHtml() => _kWebConsoleHtml;

const String _kWebConsoleHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>SA</title>
<style>
/* 全面对齐 lib/ui/theme/app_theme.dart 的淡青/深青色调、大圆角、药丸按钮、无阴影风格 */
  :root {
    --bg: #FFFFFF;
    --fg: #004D40;
    --fg-sub: #3F7F76;
    --fill: #E0F2F1;
    --fill-high: #B2DFDB;
    --divider: #CFE6E2;
    --primary: #004D40;
    --on-primary: #FFFFFF;
    --accent: #00897B;
    --input-bg: #FFFFFF;
    --dialog-bg: #FFFFFF;
    --snack-bg: #004D40;
    --snack-fg: #FFFFFF;
    --danger: #E5484D;
    --success: #00897B;
    --scrim: rgba(0, 0, 0, 0.45);
  }

  [data-theme="dark"] {
    --bg: #0F2F2B;
    --fg: #ECF5F3;
    --fg-sub: #9CC4BD;
    --fill: #17463F;
    --fill-high: #22605A;
    --divider: #1F5750;
    --primary: #FFFFFF;
    --on-primary: #004D40;
    --accent: #00897B;
    --input-bg: #123833;
    --dialog-bg: #143B36;
    --snack-bg: #ECF5F3;
    --snack-fg: #004D40;
    --danger: #E5484D;
    --success: #26A69A;
    --scrim: rgba(0, 0, 0, 0.62);
  }

  * {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    -webkit-tap-highlight-color: transparent;
    scrollbar-width: none;
    -ms-overflow-style: none;
  }

  *::-webkit-scrollbar {
    width: 0 !important;
    height: 0 !important;
    display: none !important;
  }

  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    background: var(--bg);
    color: var(--fg);
    height: 100vh;
    height: 100dvh;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transition: background-color 0.2s, color 0.2s;
  }

  /* 通用图标按钮（与 Flutter IconButton 对齐） */
  .icon-btn {
    width: 40px;
    height: 40px;
    border-radius: 999px;
    border: none;
    background: transparent;
    color: var(--fg);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: background-color 0.15s, color 0.15s, transform 0.1s;
    position: relative;
    flex-shrink: 0;
  }
  .icon-btn:hover { background: var(--fill); }
  .icon-btn:active { transform: scale(0.95); }
  .icon-btn:disabled { opacity: 0.45; cursor: not-allowed; }
  .icon-btn.accent { color: var(--accent); }
  .icon-btn.muted { color: var(--fg-sub); }
  .icon-btn.tonal {
    background: var(--fill);
    color: var(--fg);
  }
  .icon-btn.tonal:hover { background: var(--fill-high); }
  .icon-btn.outlined {
    border: 1px solid var(--divider);
  }

  svg.ic {
    width: 22px;
    height: 22px;
    fill: currentColor;
    flex-shrink: 0;
  }
  svg.ic-sm { width: 18px; height: 18px; fill: currentColor; flex-shrink: 0; }
  svg.ic-lg { width: 48px; height: 48px; fill: currentColor; flex-shrink: 0; }

  /* 药丸按钮（与 AppTheme FilledButton / OutlinedButton / TextButton 对齐） */
  .btn-filled {
    background: var(--primary);
    color: var(--on-primary);
    border: none;
    border-radius: 999px;
    min-height: 42px;
    padding: 0 22px;
    font-size: 14px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    cursor: pointer;
    transition: opacity 0.15s, transform 0.1s;
  }
  .btn-filled:hover { opacity: 0.9; }
  .btn-filled:active { transform: scale(0.98); }
  .btn-filled:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn-filled.danger {
    background: var(--danger);
    color: #FFFFFF;
  }
  .btn-filled.accent-bg {
    background: var(--accent);
    color: #FFFFFF;
  }

  .btn-outlined {
    background: transparent;
    color: var(--fg);
    border: 1px solid var(--divider);
    border-radius: 999px;
    min-height: 40px;
    padding: 0 18px;
    font-size: 13px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    cursor: pointer;
    transition: background-color 0.15s;
  }
  .btn-outlined:hover { background: var(--fill); }
  .btn-outlined:disabled { opacity: 0.5; cursor: not-allowed; }

  .btn-text {
    background: transparent;
    color: var(--fg);
    border: none;
    border-radius: 999px;
    padding: 8px 14px;
    font-size: 13px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
  }
  .btn-text:hover { background: var(--fill); }
  .btn-text.danger { color: var(--danger); }

/* 顶部 AppBar */
  .app-bar {
    height: 56px;
    width: 100%;
    max-width: 920px;
    margin: 0 auto;
    padding: 0 8px 0 12px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg);
    flex-shrink: 0;
    position: relative;
    z-index: 10;
  }
  .app-bar-left {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .app-bar-title {
    font-size: 17px;
    font-weight: 600;
    color: var(--fg);
    position: absolute;
    left: 50%;
    transform: translateX(-50%);
    pointer-events: none;
    white-space: nowrap;
  }
  .app-bar-actions {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  /* 主视图容器（全窗口宽度，支持全屏任意位置滚轮滚动，无滚动条） */
  .screen {
    display: none;
    flex: 1;
    flex-direction: column;
    overflow: hidden;
    width: 100%;
  }
  .screen.active {
    display: flex;
  }

  /* HomeScreen 顶部动态状态胶囊 (_buildStatusPill) */
  .status-pill {
    width: calc(100% - 32px);
    max-width: 888px;
    margin: 8px auto;
    padding: 10px 14px;
    background: var(--fill);
    border-radius: 24px;
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 42px;
    transition: background-color 0.2s;
    user-select: none;
  }
  .status-pill.clickable { cursor: pointer; }
  .status-pill.clickable:hover { background: var(--fill-high); }
  .status-pill-title {
    font-size: 13px;
    font-weight: 700;
    white-space: nowrap;
    color: var(--fg-sub);
  }
  .status-pill.state-active .status-pill-title,
  .status-pill.state-active .status-pill-icon {
    color: var(--accent);
  }
  .status-pill.state-thinking .status-pill-title,
  .status-pill.state-thinking .status-pill-icon {
    color: var(--fg);
  }
  .status-pill-sep {
    color: var(--fg-sub);
    opacity: 0.35;
    font-size: 12px;
  }
  .status-pill-text {
    flex: 1;
    font-size: 12px;
    color: var(--fg-sub);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .status-pill-badge {
    font-size: 10px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 4px;
    white-space: nowrap;
  }
  .status-pill-badge.matched {
    background: rgba(0, 137, 123, 0.18);
    color: var(--accent);
  }
  .status-pill-badge.unmatched {
    background: rgba(63, 127, 118, 0.14);
    color: var(--fg-sub);
  }
  .status-pill-stop {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 2px 8px;
    border-radius: 12px;
    border: none;
    background: transparent;
    color: var(--danger);
    font-size: 11px;
    font-weight: 700;
    cursor: pointer;
  }
  .status-pill-stop:hover {
    background: rgba(229, 72, 77, 0.12);
  }

  /* 顶部状态栏内的迷你实时麦克风音量计 */
  .mini-vol-wrap {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 8px;
    border-radius: 999px;
    background: rgba(0, 137, 123, 0.10);
    cursor: pointer;
    flex-shrink: 0;
  }
  .mini-vol-bars {
    display: inline-flex;
    align-items: flex-end;
    gap: 2px;
    height: 12px;
  }
  .mini-vol-bar {
    width: 3px;
    background: var(--fg-sub);
    opacity: 0.35;
    border-radius: 2px;
    transition: height 0.08s ease, background-color 0.08s ease, opacity 0.08s ease;
  }
  .mini-vol-bar.lit {
    background: var(--accent);
    opacity: 1;
  }
  .mini-vol-label {
    font-size: 10px;
    font-weight: 600;
    color: var(--fg-sub);
    min-width: 26px;
    text-align: right;
  }

  /* 顶部状态栏内的服务器实时 CPU 占用率指标 */
  .mini-cpu-wrap {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 999px;
    background: rgba(100, 116, 139, 0.12);
    cursor: default;
    flex-shrink: 0;
    user-select: none;
    transition: background-color 0.2s, color 0.2s;
  }
  .mini-cpu-wrap.high {
    background: rgba(229, 72, 77, 0.16);
  }
  .mini-cpu-label {
    font-size: 10px;
    font-weight: 600;
    color: var(--fg-sub);
    letter-spacing: 0.2px;
    white-space: nowrap;
  }
  .mini-cpu-wrap.high .mini-cpu-label {
    color: var(--danger);
  }

/* 聊天消息列表与空白态 (_buildEmptyState & _buildMessageBubble) */
  .chat-list {
    flex: 1;
    width: 100%;
    overflow-y: auto;
    padding: 8px 16px 16px 16px;
    display: flex;
    flex-direction: column;
  }
  .empty-state {
    margin: auto;
    text-align: center;
    padding: 32px;
    display: flex;
    flex-direction: column;
    align-items: center;
    max-width: 888px;
    width: 100%;
  }
  .empty-state-title { margin-top: 16px; font-size: 16px; font-weight: 600; color: var(--fg); }
  .empty-state-sub { margin-top: 8px; font-size: 13px; line-height: 1.6; color: var(--fg-sub); max-width: 420px; white-space: pre-line; }

  /* 用户消息：右对齐淡青圆角气泡；助理消息：无气泡全宽 Markdown */
  .msg-user-row {
    display: flex;
    justify-content: flex-end;
    width: 100%;
    max-width: 888px;
    margin: 8px auto;
  }
  .msg-user-bubble {
    background: var(--fill-high);
    color: var(--fg);
    padding: 10px 16px;
    border-radius: 22px;
    max-width: 80%;
    font-size: 16px;
    line-height: 1.5;
    word-break: break-word;
    white-space: pre-wrap;
  }
  .msg-unintended-row {
    display: flex;
    justify-content: flex-end;
    width: 100%;
    max-width: 888px;
    margin: 4px auto 8px auto;
  }
  .msg-unintended-bubble {
    background: var(--fill);
    border: 1px dashed var(--divider);
    border-radius: 14px;
    padding: 8px 12px;
    max-width: 80%;
    text-align: right;
  }
  .unintended-badge {
    font-size: 11px;
    color: var(--fg-sub);
    font-weight: 500;
    margin-bottom: 2px;
  }
  .unintended-text {
    font-size: 13px;
    line-height: 1.4;
    font-style: italic;
    color: var(--fg-sub);
    word-break: break-word;
    white-space: pre-wrap;
  }
  .msg-assistant-row {
    width: 100%;
    max-width: 888px;
    margin: 8px auto;
    color: var(--fg);
    font-size: 16px;
    line-height: 1.55;
    word-break: break-word;
  }
  .msg-img-wrap {
    position: relative;
    display: inline-block;
    margin: 6px 0;
    border-radius: 16px;
    overflow: hidden;
    cursor: pointer;
  }
  .msg-img-wrap img {
    width: 240px;
    height: 180px;
    object-fit: cover;
    display: block;
    border-radius: 16px;
  }
  .msg-img-zoom {
    position: absolute;
    right: 6px;
    bottom: 6px;
    background: rgba(0, 0, 0, 0.54);
    color: #FFFFFF;
    border-radius: 6px;
    padding: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  /* Markdown 样式（对齐 _buildAssistantMarkdown） */
  .md-body p { margin-bottom: 10px; }
  .md-body p:last-child { margin-bottom: 0; }
  .md-body h1 { font-size: 22px; font-weight: 700; line-height: 1.35; margin: 12px 0 6px; }
  .md-body h2 { font-size: 19px; font-weight: 700; line-height: 1.35; margin: 10px 0 6px; }
  .md-body h3 { font-size: 17px; font-weight: 600; line-height: 1.35; margin: 8px 0 4px; }
  .md-body ul, .md-body ol { padding-left: 22px; margin-bottom: 10px; }
  .md-body li { margin-bottom: 4px; }
  .md-body code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 14px;
    background: var(--fill);
    padding: 2px 5px;
    border-radius: 6px;
  }
  .md-body pre {
    background: var(--fill);
    border: 1px solid var(--divider);
    border-radius: 12px;
    padding: 12px;
    overflow-x: auto;
    margin: 8px 0;
  }
  .md-body pre code { background: transparent; padding: 0; }
  .md-body blockquote { border-left: 3px solid var(--fg-sub); padding: 6px 12px; margin: 8px 0; color: var(--fg-sub); }
  .md-body a { color: var(--accent); text-decoration: underline; }
  .think-details { background: var(--fill); border-radius: 12px; padding: 8px 12px; margin-bottom: 8px; font-size: 13px; color: var(--fg-sub); }
  .think-details summary { cursor: pointer; font-weight: 600; user-select: none; }
  .think-details .think-body { margin-top: 6px; white-space: pre-wrap; }

  /* 底部输入栏 (_buildBottomInputBar) */
  .bottom-input-bar {
    width: 100%;
    max-width: 912px;
    margin: 0 auto;
    padding: 8px 12px 12px 12px;
    background: var(--bg);
    display: flex;
    align-items: flex-end;
    gap: 8px;
    flex-shrink: 0;
  }
  .pill-input-wrap {
    flex: 1;
    background: var(--fill);
    border-radius: 26px;
    display: flex;
    align-items: center;
    padding: 4px 18px;
  }
  .pill-input {
    width: 100%;
    border: none;
    background: transparent;
    color: var(--fg);
    font-size: 15px;
    line-height: 1.45;
    padding: 9px 0;
    resize: none;
    max-height: 110px;
    outline: none;
    font-family: inherit;
  }
  .pill-input::placeholder { color: var(--fg-sub); }

  .circle-action-btn {
    width: 46px;
    height: 46px;
    border-radius: 999px;
    border: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    transition: transform 0.1s, background-color 0.15s, color 0.15s;
  }
  .circle-action-btn:active { transform: scale(0.94); }
  .circle-action-btn.mic-btn { background: var(--fill); color: var(--fg); }
  .circle-action-btn.mic-btn.listening { color: var(--accent); }
  .circle-action-btn.mic-btn.recording { background: var(--danger); color: #FFFFFF; }
  .circle-action-btn.send-btn { background: var(--primary); color: var(--on-primary); }

/* 左侧抽屉 ChatHistoryDrawer */
  .drawer-backdrop {
    position: fixed;
    inset: 0;
    background: var(--scrim);
    z-index: 90;
    display: none;
  }
  .drawer-backdrop.open { display: block; }
  .history-drawer {
    position: fixed;
    top: 0;
    left: 0;
    bottom: 0;
    width: 304px;
    max-width: 84vw;
    background: var(--bg);
    z-index: 100;
    transform: translateX(-100%);
    transition: transform 0.22s cubic-bezier(0.4, 0, 0.2, 1);
    display: flex;
    flex-direction: column;
    border-right: 1px solid var(--divider);
  }
  .history-drawer.open { transform: translateX(0); }
  .drawer-search-box {
    margin: 12px 12px 8px;
    background: var(--fill);
    border-radius: 24px;
    display: flex;
    align-items: center;
    padding: 0 12px;
    height: 40px;
    gap: 8px;
  }
  .drawer-search-box input {
    flex: 1;
    border: none;
    background: transparent;
    color: var(--fg);
    font-size: 14px;
    outline: none;
  }
  .drawer-search-box input::placeholder { color: var(--fg-sub); }
  .drawer-session-list {
    flex: 1;
    overflow-y: auto;
    padding: 8px;
  }
  .drawer-group-title {
    padding: 10px 12px 4px;
    font-size: 11px;
    font-weight: 700;
    color: var(--fg-sub);
  }
  .session-tile {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 6px 8px 12px;
    margin: 2px 0;
    border-radius: 10px;
    cursor: pointer;
    color: var(--fg);
    transition: background-color 0.12s;
  }
  .session-tile:hover { background: var(--fill); }
  .session-tile.selected {
    background: var(--fill);
    font-weight: 700;
  }
  .session-tile-title {
    flex: 1;
    font-size: 13px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .session-tile-actions {
    display: flex;
    gap: 2px;
    opacity: 0.7;
  }
  .session-tile:hover .session-tile-actions { opacity: 1; }
  .drawer-footer {
    border-top: 1px solid var(--divider);
    padding: 6px 12px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

/* SettingsScreen 样式（对齐 lib/ui/screens/settings_screen.dart，全窗口宽度可滚动） */
  .settings-scroll {
    flex: 1;
    width: 100%;
    overflow-y: auto;
    padding: 16px;
  }
  .section-header {
    width: 100%;
    max-width: 888px;
    margin: 24px auto 0 auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 0 8px 4px;
  }
  .section-header:first-child { margin-top: 0; }
  .section-header h3 {
    font-size: 16px;
    font-weight: 700;
    color: var(--fg);
  }
  .settings-card {
    width: 100%;
    max-width: 888px;
    margin: 0 auto;
    background: var(--fill);
    border-radius: 20px;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .card-divider {
    height: 1px;
    background: var(--divider);
    margin: 6px 0;
    border: none;
  }
  .field-group {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .field-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--fg-sub);
  }
  .m3-input, .m3-select, .m3-textarea {
    width: 100%;
    background: var(--input-bg);
    color: var(--fg);
    border: 1px solid var(--divider);
    border-radius: 12px;
    padding: 11px 14px;
    font-size: 14px;
    font-family: inherit;
    outline: none;
    transition: border-color 0.15s;
  }
  .m3-input:focus, .m3-select:focus, .m3-textarea:focus {
    border-color: var(--accent);
    border-width: 1.5px;
  }
  .m3-textarea { resize: vertical; min-height: 82px; line-height: 1.45; }

  /* SwitchListTile 对齐 */
  .switch-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 0;
    gap: 12px;
    cursor: pointer;
    user-select: none;
  }
  .switch-row-title {
    font-size: 15px;
    color: var(--fg);
  }
  .m3-switch {
    position: relative;
    width: 48px;
    height: 26px;
    flex-shrink: 0;
  }
  .m3-switch input { opacity: 0; width: 0; height: 0; }
  .m3-switch-track {
    position: absolute;
    inset: 0;
    background: #9CCCC5;
    border-radius: 999px;
    transition: background-color 0.2s;
  }
  [data-theme="dark"] .m3-switch-track { background: #3A7A72; }
  .m3-switch-thumb {
    position: absolute;
    top: 3px;
    left: 3px;
    width: 20px;
    height: 20px;
    background: #FFFFFF;
    border-radius: 50%;
    transition: transform 0.2s;
  }
  .m3-switch input:checked + .m3-switch-track {
    background: var(--accent);
  }
  .m3-switch input:checked + .m3-switch-track .m3-switch-thumb {
    transform: translateX(22px);
  }

  /* Slider 对齐 */
  .slider-row {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 4px 0;
  }
  .slider-col {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 4px 0;
  }
  .slider-label {
    font-size: 14px;
    color: var(--fg);
    white-space: nowrap;
  }
  input[type="range"].m3-slider {
    -webkit-appearance: none;
    appearance: none;
    flex: 1;
    width: 100%;
    height: 4px;
    background: var(--fill-high);
    border-radius: 4px;
    outline: none;
  }
  input[type="range"].m3-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: var(--primary);
    cursor: pointer;
  }

  /* ExpansionTile 对齐 */
  details.m3-expansion {
    border: none;
  }
  details.m3-expansion > summary {
    list-style: none;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 0;
    font-size: 15px;
    color: var(--fg);
    cursor: pointer;
    user-select: none;
  }
  details.m3-expansion > summary::-webkit-details-marker { display: none; }
  details.m3-expansion > summary::after {
    content: "▾";
    color: var(--fg-sub);
    font-size: 14px;
    transition: transform 0.2s;
  }
  details.m3-expansion[open] > summary::after {
    transform: rotate(180deg);
  }
  .expansion-body {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 6px 0 4px;
  }

/* 麦克风测试与音量可视化专属面板 */
  .mic-test-panel {
    background: var(--input-bg);
    border: 1px solid var(--divider);
    border-radius: 16px;
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .vol-meter-track {
    height: 14px;
    background: var(--fill);
    border-radius: 999px;
    overflow: hidden;
    position: relative;
  }
  .vol-meter-fill {
    height: 100%;
    width: 0%;
    background: linear-gradient(90deg, var(--accent) 0%, #26A69A 70%, #FFA726 100%);
    border-radius: 999px;
    transition: width 0.08s linear;
  }
  .mic-test-live-box {
    background: var(--fill);
    border-radius: 12px;
    padding: 12px 14px;
    min-height: 48px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .mic-test-history {
    max-height: 220px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .mic-test-item {
    font-size: 13px;
    padding: 8px 12px;
    border-radius: 8px;
    background: var(--fill);
    display: flex;
    flex-direction: column;
    gap: 6px;
    border: 1px solid transparent;
    transition: background 0.15s, border-color 0.15s;
  }
  .mic-test-item:hover {
    border-color: var(--divider);
  }
  .mic-test-header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
  }
  .mic-test-text {
    flex: 1;
    font-weight: 500;
    line-height: 1.4;
    word-break: break-word;
  }
  .mic-test-meta {
    font-size: 11px;
    color: var(--fg-sub);
    white-space: nowrap;
  }
  .mic-test-tags {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
  }
  .mic-badge {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 12px;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    line-height: 1.3;
  }
  .mic-badge.badge-matched {
    background: rgba(0, 137, 123, 0.15);
    color: var(--accent);
  }
  .mic-badge.badge-unmatched {
    background: rgba(229, 57, 53, 0.15);
    color: var(--danger);
  }
  .mic-badge.badge-reply {
    background: rgba(30, 136, 229, 0.15);
    color: #1e88e5;
  }
  .mic-badge.badge-neutral {
    background: rgba(140, 140, 140, 0.15);
    color: var(--fg-sub);
  }
  .mic-badge.badge-muted {
    background: rgba(100, 116, 139, 0.12);
    color: var(--fg-sub);
  }
  .mic-badge.badge-info {
    background: rgba(245, 158, 11, 0.15);
    color: #d97706;
  }

  /* 顶部快捷音量弹出卡片 */
  .popover-card {
    position: fixed;
    top: 58px;
    right: 16px;
    width: 300px;
    background: var(--dialog-bg);
    border: 1px solid var(--divider);
    border-radius: 20px;
    padding: 16px;
    z-index: 85;
    display: none;
    flex-direction: column;
    gap: 12px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.14);
  }
  .popover-card.open { display: flex; }

  /* 模态框 (AlertDialog & Fullscreen Image Viewer) */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: var(--scrim);
    z-index: 120;
    display: none;
    align-items: center;
    justify-content: center;
    padding: 16px;
  }
  .modal-backdrop.open { display: flex; }
  .alert-dialog {
    background: var(--dialog-bg);
    border-radius: 28px;
    padding: 24px;
    width: 100%;
    max-width: 400px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  .alert-dialog-title {
    font-size: 18px;
    font-weight: 600;
    color: var(--fg);
  }
  .alert-dialog-content {
    font-size: 15px;
    line-height: 1.45;
    color: var(--fg-sub);
  }
  .alert-dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }

  /* SnackBar 浮动提示 */
  .snackbar {
    position: fixed;
    bottom: 20px;
    left: 50%;
    transform: translateX(-50%) translateY(20px);
    background: var(--snack-bg);
    color: var(--snack-fg);
    padding: 12px 20px;
    border-radius: 16px;
    font-size: 14px;
    font-weight: 500;
    z-index: 200;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.2s, transform 0.2s;
  }
  .snackbar.show {
    opacity: 1;
    transform: translateX(-50%) translateY(0);
  }

  .mono-log {
    background: var(--input-bg);
    border: 1px solid var(--divider);
    border-radius: 12px;
    padding: 12px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.6;
    max-height: 220px;
    overflow-y: auto;
    white-space: pre-wrap;
    color: var(--fg);
  }

  /* 话筒音源徽标：BT / 内置 / 外接，蓝牙监听时用蓝色整体着色 */
  .mic-source-badge {
    position: absolute;
    right: 1px;
    bottom: 1px;
    min-width: 14px;
    height: 12px;
    padding: 0 2px;
    border-radius: 6px;
    font-size: 8px;
    line-height: 12px;
    font-weight: 700;
    color: #fff;
    text-align: center;
    white-space: nowrap;
    pointer-events: none;
  }
  .mic-source-badge[hidden] { display: none; }
  .mic-source-badge.k-bluetooth { background: #1E88E5; }
  .mic-source-badge.k-builtIn { background: var(--accent); }
  .mic-source-badge.k-external { background: #EF6C00; }
  .icon-btn.bt-source.accent { color: #1E88E5; }
  .icon-btn.ext-source.accent { color: #EF6C00; }
</style>
</head>
<body>

<!-- ==================== 左侧历史对话抽屉 (ChatHistoryDrawer) ==================== -->
<div class="drawer-backdrop" id="drawerBackdrop" onclick="closeDrawer()"></div>
<aside class="history-drawer" id="historyDrawer">
  <div class="drawer-search-box">
    <svg class="ic-sm" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
    <input type="text" id="drawerSearchInput" placeholder="搜索历史对话..." oninput="renderDrawerSessions()">
    <button class="icon-btn" id="drawerSearchClearBtn" style="width:28px;height:28px;display:none;" onclick="clearDrawerSearch()">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
    </button>
  </div>
  <div class="drawer-session-list" id="drawerSessionList"></div>
  <div class="drawer-footer" id="drawerFooter" style="display:none;">
    <button class="btn-text" onclick="exportAllHistoryHtml()">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>
      <span>导出对话历史 (HTML)</span>
    </button>
    <button class="btn-text danger" onclick="openClearAllDialog()">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M15 16h4v2h-4zm0-8h7v2h-7zm0 4h6v2h-6zM3 18c0 1.1.9 2 2 2h6c1.1 0 2-.9 2-2V8H3v10zM14 5h-3l-1-1H6L5 5H2v2h12z"/></svg>
      <span>清空历史对话</span>
    </button>
  </div>
</aside>

<!-- ==================== 快捷音量调节弹出卡片 ==================== -->
<div class="popover-card" id="volumePopover">
  <div style="display:flex;align-items:center;justify-content:space-between;">
    <span style="font-size:14px;font-weight:700;">服务器播放音量</span>
    <span id="popoverVolLabel" style="font-size:13px;font-weight:700;color:var(--accent);">80%</span>
  </div>
  <div class="slider-row">
    <svg class="ic-sm" viewBox="0 0 24 24"><path d="M7 9v6h4l5 5V4l-5 5H7z"/></svg>
    <input type="range" class="m3-slider" id="popoverVolSlider" min="0" max="100" step="1" value="80" oninput="onVolumeSliderInput(this.value)" onchange="commitVolumeChange(this.value)">
    <svg class="ic-sm" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>
  </div>
  <div style="display:flex;justify-content:space-between;gap:8px;">
    <button class="btn-outlined" style="flex:1;min-height:36px;" onclick="previewServerVoice()">试听音量</button>
    <button class="btn-outlined" style="min-height:36px;" onclick="openMicTestInSettings()">测麦克风</button>
  </div>
</div>

<!-- ==================== 1. 主界面 (HomeScreen) ==================== -->
<main class="screen active" id="homeScreen">
  <header class="app-bar">
    <div class="app-bar-left">
      <button class="icon-btn" title="历史对话" onclick="openDrawer()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
      </button>
    </div>
    <div class="app-bar-actions">
      <!-- 服务器播放音量快捷按钮 -->
      <button class="icon-btn" id="appBarVolBtn" title="调整服务器播放音量" onclick="toggleVolumePopover(event)">
        <svg class="ic" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>
      </button>
      <!-- 拍照并问 AI -->
      <button class="icon-btn" id="cameraCaptureBtn" title="拍照并问 AI「这是什么，介绍一下」" onclick="captureAndAsk()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M20 4h-3.17L15 2H9L7.17 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 14H4V6h4.05l1.83-2h4.24l1.83 2H20v12zM12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zm0 8c-1.65 0-3-1.35-3-3s1.35-3 3-3 3 1.35 3 3-1.35 3-3 3z"/></svg>
      </button>
      <!-- 话筒监听开关 -->
      <button class="icon-btn muted" id="micToggleBtn" title="话筒已静音（点击开启）" onclick="toggleMic()">
        <svg class="ic" id="micToggleIcon" viewBox="0 0 24 24"><path d="M19 11h-1.7c0 .74-.16 1.43-.43 2.05l1.23 1.23c.56-.98.9-2.09.9-3.28zm-4.02.17c0-.06.02-.11.02-.17V5c0-1.66-1.34-3-3-3S9 3.34 9 5v.18l5.98 5.99zM4.27 3L3 4.27l6.01 6.01V11c0 1.66 1.33 3 2.99 3 .22 0 .44-.03.65-.08l1.66 1.66c-.71.33-1.5.52-2.31.52-2.76 0-5.3-2.1-5.3-5.1H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c.91-.13 1.77-.45 2.54-.9L19.73 21 21 19.73 4.27 3z"/></svg>
        <span class="mic-source-badge" id="micSourceBadge" hidden></span>
      </button>
      <!-- 新起会话 -->
      <button class="icon-btn" id="resetBtn" title="新起一个会话（重置上下文）" onclick="resetSession()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 14h-3v3h-2v-3H8v-2h3v-3h2v3h3v2zm-3-7V3.5L18.5 9H13z"/></svg>
      </button>
      <!-- 深浅色切换 -->
      <button class="icon-btn" title="切换深色/浅色模式" onclick="toggleTheme()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.389 5.389 0 0 1-4.4 2.26 5.403 5.403 0 0 1-3.14-9.8c-.44-.06-.9-.1-1.36-.1z"/></svg>
      </button>
      <!-- 设置 -->
      <button class="icon-btn" id="settingsBtn" title="设置" onclick="openSettingsScreen()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>
      </button>
    </div>
  </header>

  <!-- 顶部动态状态挂件 (_buildStatusPill) -->
  <div class="status-pill" id="statusPill" onclick="onStatusPillClick()">
    <span class="status-pill-icon" id="statusPillIcon">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.389 5.389 0 0 1-4.4 2.26 5.403 5.403 0 0 1-3.14-9.8c-.44-.06-.9-.1-1.36-.1z"/></svg>
    </span>
    <span class="status-pill-title" id="statusPillTitle">低功耗待机中</span>
    <span class="status-pill-sep">|</span>
    <span class="status-pill-text" id="statusPillText">正在连接服务器...</span>
    <span class="status-pill-badge" id="statusPillBadge" style="display:none;"></span>
    <!-- 实时麦克风音量微缩指示器（点击可直达麦克风测试面板） -->
    <div class="mini-vol-wrap" id="miniVolWrap" title="实时语音音量（点击进入麦克风与语音识别测试）" style="display:none;" onclick="event.stopPropagation(); openMicTestInSettings();">
      <div class="mini-vol-bars">
        <div class="mini-vol-bar" id="mvBar1" style="height:3px;"></div>
        <div class="mini-vol-bar" id="mvBar2" style="height:5px;"></div>
        <div class="mini-vol-bar" id="mvBar3" style="height:7px;"></div>
        <div class="mini-vol-bar" id="mvBar4" style="height:10px;"></div>
        <div class="mini-vol-bar" id="mvBar5" style="height:12px;"></div>
      </div>
      <span class="mini-vol-label" id="miniVolLabel">0%</span>
    </div>
    <!-- 服务器实时 CPU 占用率指标（置于麦克风音量右侧） -->
    <div class="mini-cpu-wrap" id="miniCpuWrap" title="服务器实时 CPU 占用率" onclick="event.stopPropagation();">
      <svg class="ic-sm" style="width:12px;height:12px;opacity:0.75;" viewBox="0 0 24 24"><path d="M15 9H9v6h6V9zm-2 4h-2v-2h2v2zm8-2V9h-2V7c0-1.1-.9-2-2-2h-2V3h-2v2h-2V3H9v2H7c-1.1 0-2 .9-2 2v2H3v2h2v2H3v2h2v2c0 1.1.9 2 2 2h2v2h2v-2h2v2h2v-2h2c1.1 0 2-.9 2-2v-2h2v-2h-2v-2h2zm-4 6H7V7h10v10z"/></svg>
      <span class="mini-cpu-label" id="miniCpuLabel">CPU --%</span>
    </div>
    <!-- 朗读中的打断按钮 -->
    <button class="status-pill-stop" id="statusPillStopBtn" style="display:none;" onclick="event.stopPropagation(); interruptSpeaking();">
      <svg class="ic-sm" style="width:15px;height:15px;" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4 14H8V8h8v8z"/></svg>
      <span>打断</span>
    </button>
  </div>

  <!-- 对话消息列表 -->
  <div class="chat-list" id="chatList"></div>

  <!-- 底部控制与测试输入条 (_buildBottomInputBar) -->
  <div class="bottom-input-bar">
    <div class="pill-input-wrap">
      <textarea class="pill-input" id="chatInput" rows="1" placeholder="输入消息直接发送..." onkeydown="onChatInputKey(event)" oninput="autoGrowInput(this)"></textarea>
    </div>
    <button class="circle-action-btn mic-btn" id="micRecordBtn" title="点按对讲录音（直接发送，免唤醒词）" onclick="toggleManualRecord()">
      <svg class="ic" id="micRecordIcon" viewBox="0 0 24 24"><path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/></svg>
    </button>
    <button class="circle-action-btn send-btn" id="sendBtn" title="发送消息" onclick="sendChat()">
      <svg class="ic" viewBox="0 0 24 24"><path d="M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z"/></svg>
    </button>
  </div>
</main>

<!-- ==================== 2. 助手设置界面 (SettingsScreen) ==================== -->
<section class="screen" id="settingsScreen">
  <header class="app-bar">
    <div class="app-bar-left">
      <button class="icon-btn" title="返回" onclick="closeSettingsScreen()">
        <svg class="ic" viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
      </button>
    </div>
    <span class="app-bar-title">助手设置</span>
    <div class="app-bar-actions">
      <span id="autoSaveBadge" style="font-size:12px;color:var(--fg-sub);padding-right:8px;">自动保存</span>
    </div>
  </header>

  <div class="settings-scroll" id="settingsScroll">
    <!-- 1. 对话管线模式与语音识别 -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M7 18h2V6H7v12zm4 4h2V2h-2v20zm-8-8h2v-4H3v4zm12 4h2V6h-2v12zm4-8v4h2v-4h-2z"/></svg>
      <h3>对话管线模式与语音识别</h3>
    </div>
    <div class="settings-card">
      <div class="field-group">
        <label class="field-label">交互架构模式</label>
        <select class="m3-select" id="cfg_pipelineMode" onchange="onPipelineModeChanged(); scheduleAutoSave(true)">
          <option value="cascade">标准级联模式（独立 ASR + LLM + TTS）</option>
          <option value="gemini_live">Gemini 3.8 Live 全双工模式（端到端语音大模型）</option>
        </select>
      </div>

      <div class="field-group" id="cascadeAsrEngineGroup">
        <label class="field-label">识别模型（级联模式）</label>
        <select class="m3-select" id="cfg_asrEngine" onchange="scheduleAutoSave(true)">
          <option value="sensevoice">高精度离线 SenseVoice（内置，推荐）</option>
          <option value="streaming">低延迟流式 Zipformer（内置小模型）</option>
          <option value="gemini_live">Gemini 3.5 Transcribe Live（云端，需联网）</option>
        </select>
      </div>

      <details class="m3-expansion" id="geminiCloudExpansion">
        <summary id="geminiCloudSummary">Gemini Live 云端配置（3.8 全双工 / 3.5 语音转写）</summary>
        <div class="expansion-body">
          <div class="field-group">
            <label class="field-label">Gemini API Key</label>
            <input type="password" class="m3-input" id="cfg_geminiApiKey" oninput="scheduleAutoSave()">
          </div>
          <div id="geminiLiveFieldsGroup">
            <div class="field-group">
              <label class="field-label">Gemini 3.8 Live 全双工模型</label>
              <input type="text" class="m3-input" id="cfg_geminiLiveModel" placeholder="gemini-3.8-live" oninput="scheduleAutoSave()">
            </div>
            <div class="field-group" style="margin-top:8px;">
              <label class="field-label">Gemini 3.8 Live 原生音色 (Voice)</label>
              <select class="m3-select" id="cfg_geminiLiveVoice" onchange="scheduleAutoSave(true)">
                <option value="Aoede">Aoede（自然轻快女声 · 默认）</option>
                <option value="Zephyr">Zephyr（明亮清脆女声）</option>
                <option value="Puck">Puck（活泼阳光男声）</option>
                <option value="Charon">Charon（沉稳知性男声）</option>
                <option value="Kore">Kore（坚定干练女声）</option>
                <option value="Fenrir">Fenrir（热情活力男声）</option>
                <option value="Leda">Leda（青春元气女声）</option>
                <option value="Orus">Orus（稳重有力男声）</option>
                <option value="Callirrhoe">Callirrhoe（随和亲切女声）</option>
                <option value="Autonoe">Autonoe（明快爽朗女声）</option>
                <option value="Enceladus">Enceladus（柔和空气感男声）</option>
                <option value="Iapetus">Iapetus（清晰透亮男声）</option>
                <option value="Umbriel">Umbriel（随性从容男声）</option>
                <option value="Algieba">Algieba（温润顺滑男声）</option>
                <option value="Despina">Despina（柔美顺滑女声）</option>
                <option value="Erinome">Erinome（清亮知性女声）</option>
                <option value="Algenib">Algenib（磁性低沉男声）</option>
                <option value="Rasalgethi">Rasalgethi（专业播报男声）</option>
                <option value="Laomedeia">Laomedeia（欢快明丽女声）</option>
                <option value="Achernar">Achernar（轻柔温婉女声）</option>
                <option value="Alnilam">Alnilam（刚毅果断男声）</option>
                <option value="Schedar">Schedar（平实稳健男声）</option>
                <option value="Gacrux">Gacrux（成熟醇厚女声）</option>
                <option value="Pulcherrima">Pulcherrima（大气直率女声）</option>
                <option value="Achird">Achird（友善温暖男声）</option>
                <option value="Zubenelgenubi">Zubenelgenubi（轻松休闲男声）</option>
                <option value="Vindemiatrix">Vindemiatrix（温柔恬静女声）</option>
                <option value="Sadachbia">Sadachbia（生动活泼男声）</option>
                <option value="Sadaltager">Sadaltager（博学睿智男声）</option>
                <option value="Sulafat">Sulafat（温暖治愈女声）</option>
                <option value="Fola">Fola（亲切自然女声）</option>
              </select>
            </div>
            <div class="field-group" style="margin-top:8px;">
              <label class="field-label">Gemini Live 对话模式</label>
              <select class="m3-select" id="cfg_geminiLiveAdvancedMode" onchange="scheduleAutoSave(true)">
                <option value="auto">自动(按模型判断)</option>
                <option value="advanced">高级(Extended Thinking)</option>
                <option value="basic">初级</option>
              </select>
            </div>
            <div class="field-group" style="margin-top:8px;">
              <label class="field-label">Gemini Live 思考级别</label>
              <select class="m3-select" id="cfg_geminiLiveThinkingLevel" onchange="scheduleAutoSave(true)">
                <option value="low">低</option>
                <option value="medium">中</option>
                <option value="high">高</option>
              </select>
            </div>
            <label class="switch-row" style="margin-top:8px;">
              <span class="switch-row-title">显示思考摘要</span>
              <span class="m3-switch">
                <input type="checkbox" id="cfg_geminiLiveIncludeThoughts" onchange="scheduleAutoSave(true)">
                <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
              </span>
            </label>
          </div>
          <div class="field-group" id="geminiAsrModelGroup">
            <label class="field-label">Gemini 语音转写模型（级联模式）</label>
            <input type="text" class="m3-input" id="cfg_geminiAsrModel" oninput="scheduleAutoSave()">
          </div>
          <div>
            <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
              <button class="btn-outlined" id="testGeminiBtn" onclick="testGeminiConnection()">测试连接</button>
              <button class="btn-outlined" id="previewGeminiVoiceBtn" onclick="previewGeminiLiveVoice()">试听当前音色</button>
            </div>
            <div id="geminiTestResult" style="font-size:12px;margin-top:6px;"></div>
          </div>
        </div>
      </details>

      <hr class="card-divider">

      <!-- 录音设备与麦克风测试 -->
      <div style="display:flex;align-items:center;justify-content:space-between;">
        <div style="display:flex;align-items:center;gap:6px;">
          <svg class="ic-sm" viewBox="0 0 24 24"><path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20h2v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/></svg>
          <span style="font-size:14px;font-weight:600;">录音设备与麦克风测试</span>
        </div>
        <button class="btn-text" onclick="loadHardwareDevices()">重新扫描</button>
      </div>
      <div class="field-group">
        <label class="field-label">录音输入源</label>
        <select class="m3-select" id="cfg_audioInputDeviceId" onchange="onAudioInputSelectChanged()"></select>
      </div>

      <!-- 麦克风实时音量与语音识别文字测试面板 -->
      <div class="mic-test-panel" id="micTestPanel">
        <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;">
          <div>
            <div style="font-size:14px;font-weight:700;">麦克风语音音量 & 识别文字实时测试</div>
            <div style="font-size:12px;color:var(--fg-sub);">开启测试后对着服务器麦克风说话，实时查看音量跳动与语音识别出的文字（不触发大模型回复）</div>
          </div>
          <div style="display:flex;gap:8px;">
            <button class="btn-filled accent-bg" id="micTestToggleBtn" style="min-height:36px;padding:0 16px;" onclick="toggleMicTestMode()">开始麦克风测试</button>
            <button class="btn-outlined" style="min-height:36px;padding:0 12px;" onclick="clearMicTestHistory()">清空</button>
          </div>
        </div>

        <!-- 实时语音音量条 -->
        <div style="display:flex;flex-direction:column;gap:6px;">
          <div style="display:flex;align-items:center;justify-content:space-between;font-size:12px;">
            <span>检测语音音量: <strong id="micTestVolPercent" style="color:var(--accent);">0%</strong> (<span id="micTestDbfs">-60.0 dB</span>)</span>
            <span id="micTestVadBadge" style="padding:2px 8px;border-radius:999px;background:var(--fill);color:var(--fg-sub);font-weight:600;">静音待机</span>
          </div>
          <div class="vol-meter-track">
            <div class="vol-meter-fill" id="micTestVolFill"></div>
          </div>
        </div>

        <!-- 最新语音识别文字内容 -->
        <div class="mic-test-live-box">
          <div style="font-size:11px;font-weight:600;color:var(--fg-sub);">最新语音识别文字内容：</div>
          <div id="micTestLatestText" style="font-size:16px;font-weight:600;color:var(--fg);">等待对着服务器麦克风说话...</div>
          <div id="micTestLatestBadges" class="mic-test-tags" style="margin-top:4px;"></div>
        </div>

        <!-- 历史识别列表 -->
        <div class="mic-test-history" id="micTestHistoryList"></div>
      </div>

      <hr class="card-divider">

      <label class="switch-row">
        <span class="switch-row-title">静音超时自动提交</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_autoSubmitOnTimeout" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>

      <details class="m3-expansion">
        <summary>高级 VAD / 分段参数</summary>
        <div class="expansion-body">
          <div class="slider-col">
            <span class="slider-label">VAD 语音阈值: <span id="lbl_vadThreshold">0.40</span></span>
            <input type="range" class="m3-slider" id="cfg_vadThreshold" min="0.20" max="0.80" step="0.05" oninput="updateSliderLabel('vadThreshold', Number(this.value).toFixed(2)); scheduleAutoSave();">
          </div>
          <div class="slider-col">
            <span class="slider-label">尾静音判定: <span id="lbl_vadMinSilenceSeconds">0.50 秒</span></span>
            <input type="range" class="m3-slider" id="cfg_vadMinSilenceSeconds" min="0.20" max="1.20" step="0.05" oninput="updateSliderLabel('vadMinSilenceSeconds', Number(this.value).toFixed(2)+' 秒'); scheduleAutoSave();">
          </div>
          <div class="slider-col">
            <span class="slider-label">最短语音: <span id="lbl_vadMinSpeechSeconds">0.25 秒</span></span>
            <input type="range" class="m3-slider" id="cfg_vadMinSpeechSeconds" min="0.10" max="0.60" step="0.05" oninput="updateSliderLabel('vadMinSpeechSeconds', Number(this.value).toFixed(2)+' 秒'); scheduleAutoSave();">
          </div>
          <div class="slider-col">
            <span class="slider-label">最长语音: <span id="lbl_vadMaxSpeechSeconds">30 秒</span></span>
            <input type="range" class="m3-slider" id="cfg_vadMaxSpeechSeconds" min="10" max="60" step="5" oninput="updateSliderLabel('vadMaxSpeechSeconds', Number(this.value).toFixed(0)+' 秒'); scheduleAutoSave();">
          </div>
          <div class="slider-col">
            <span class="slider-label">段前预卷: <span id="lbl_preRollMs">300 毫秒</span></span>
            <input type="range" class="m3-slider" id="cfg_preRollMs" min="0" max="500" step="50" oninput="updateSliderLabel('preRollMs', Number(this.value).toFixed(0)+' 毫秒'); scheduleAutoSave();">
          </div>
          <div class="slider-col">
            <span class="slider-label">段尾补静音: <span id="lbl_postRollMs">200 毫秒</span></span>
            <input type="range" class="m3-slider" id="cfg_postRollMs" min="0" max="500" step="50" oninput="updateSliderLabel('postRollMs', Number(this.value).toFixed(0)+' 毫秒'); scheduleAutoSave();">
          </div>
        </div>
      </details>
    </div>

    <!-- 2. 语音唤醒与连续对话 -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M9 9m-4 0a4 4 0 1 0 8 0a4 4 0 1 0 -8 0M9 15c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4zm7.76-9.64l-1.68 1.69c.84 1.18.84 2.71 0 3.89l1.68 1.69c2.02-2.02 2.02-5.07 0-7.27zM20.07 2l-1.63 1.63c2.77 3.02 2.77 7.56 0 10.74L20.07 16c3.9-3.89 3.91-9.95 0-14z"/></svg>
      <h3>语音唤醒与连续对话</h3>
    </div>
    <div class="settings-card">
      <div class="field-group">
        <label class="field-label">唤醒交互模式</label>
        <select class="m3-input" id="cfg_startWordMode" onchange="onStartWordModeChange(); scheduleAutoSave(true)">
          <option value="enabled">1. 启用（每次均需称呼名字唤醒）</option>
          <option value="disabled">2. 关闭（无需称呼名字，直接交互）</option>
          <option value="auto">3. 自动（唤醒后进入连续对话）</option>
        </select>
        <div id="desc_startWordMode" style="font-size:12px;color:var(--fg-sub);margin-top:4px;">
          自动模式：唤醒后进入连续对话，由大模型智能理解对话意图；无对话超时或大模型识别到结束意图自动退出。
        </div>
      </div>
      <div class="field-group" id="group_continuousTimeout">
        <label class="field-label">连续对话退出时间: <span id="lbl_continuousModeTimeoutMinutes">10</span> 分钟</label>
        <input type="range" class="m3-slider" id="cfg_continuousModeTimeoutMinutes" min="1" max="60" value="10"
               oninput="document.getElementById('lbl_continuousModeTimeoutMinutes').textContent = this.value; scheduleAutoSave()">
      </div>
      <hr class="card-divider">
      <div class="field-group">
        <label class="field-label">唤醒名字（如：晓漫，支持分号分隔多个别名）</label>
        <input type="text" class="m3-input" id="cfg_startWord" oninput="scheduleAutoSave()">
      </div>
      <div class="slider-row">
        <span class="slider-label">静音断句超时: <span id="lbl_silenceTimeoutSeconds">10 秒</span></span>
        <input type="range" class="m3-slider" id="cfg_silenceTimeoutSeconds" min="0.1" max="10" step="0.1" oninput="updateSliderLabel('silenceTimeoutSeconds', fmtSilenceSecLabel(this.value)); scheduleAutoSave();">
        <div style="font-size:11px;color:var(--fg-sub);margin-top:4px;">倾听时多久没听到声音就结束本轮（0.1~10 秒，步进 0.1 秒）</div>
      </div>
    </div>

    <!-- 主人声纹识别（声纹锁） -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M12 1a9 9 0 0 0-9 9v1a1 1 0 0 0 2 0v-1a7 7 0 0 1 14 0v1a1 1 0 0 0 2 0v-1a9 9 0 0 0-9-9zm0 4a5 5 0 0 0-5 5v1a1 1 0 0 0 2 0v-1a3 3 0 0 1 6 0v1a1 1 0 0 0 2 0v-1a5 5 0 0 0-5-5zm0 8a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"/></svg>
      <h3>主人声纹识别（声纹锁）</h3>
    </div>
    <div class="settings-card">
      <label class="switch-row">
        <div>
          <span class="switch-row-title">启用主人声纹识别</span>
          <div style="font-size:12px;color:var(--fg-sub);">仅响应已录入的主人声音，防止旁人闲聊或电视声音误唤醒</div>
        </div>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableSpeakerVerification" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <div id="speakerVerificationPanel">
        <label class="switch-row" style="margin-top:8px;">
          <div>
            <span class="switch-row-title">仅在唤醒与打断时校验</span>
            <div style="font-size:12px;color:var(--fg-sub);">推荐开启。避免提问时极短词（如“回答”）因有效语音过短而被拦截</div>
          </div>
          <span class="m3-switch">
            <input type="checkbox" id="cfg_speakerVerifyWakeOnly" onchange="scheduleAutoSave(true)">
            <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
          </span>
        </label>
        <div class="slider-row" style="margin-top:8px;">
          <span class="slider-label">声纹匹配阈值: <span id="lbl_speakerSimilarityThreshold">55%</span></span>
          <input type="range" class="m3-slider" id="cfg_speakerSimilarityThreshold" min="0.35" max="0.85" step="0.01" oninput="updateSliderLabel('speakerSimilarityThreshold', Math.round(this.value*100)+'%'); scheduleAutoSave();">
        </div>
        <div style="font-size:11px;color:var(--fg-sub);margin-bottom:8px;">较宽松 (45%) ~ 推荐 (55%~60%) ~ 较严格 (70%)</div>
        <div class="slider-row" style="margin-top:8px;">
          <span class="slider-label">有效人声最短时长: <span id="lbl_speakerMinSpeechSeconds">0.30 秒</span></span>
          <input type="range" class="m3-slider" id="cfg_speakerMinSpeechSeconds" min="0.20" max="0.60" step="0.05" oninput="updateSliderLabel('speakerMinSpeechSeconds', Number(this.value).toFixed(2)+' 秒'); scheduleAutoSave();">
        </div>
        <div style="font-size:11px;color:var(--fg-sub);margin-bottom:8px;">声纹识别所需的最短语音（短唤醒词如“小满”建议 0.25~0.35s，可调范围 0.20s~0.60s）</div>
        <div class="slider-row" style="margin-top:8px;">
          <span class="slider-label">有效人声起振能量门限: <span id="lbl_speakerEnergyThreshold">0.00005</span></span>
          <input type="range" class="m3-slider" id="cfg_speakerEnergyThreshold" min="0.00001" max="0.00025" step="0.00001" oninput="updateSliderLabel('speakerEnergyThreshold', Number(this.value).toFixed(5)); scheduleAutoSave();">
        </div>
        <div style="font-size:11px;color:var(--fg-sub);margin-bottom:8px;">声纹起振所需最小能量（3~5米远场或低增益蓝牙麦建议 0.00003~0.00008，近场防噪建议 0.00015~0.00020）</div>
        <hr class="card-divider">
        <label class="switch-row" style="margin-top:8px;">
          <div>
            <span class="switch-row-title">目标说话人语音抽取 (TSE 智能滤声)</span>
            <div style="font-size:12px;color:var(--fg-sub);">【方案二】利用主人声纹波形分离，消除电视背景音与户外路人闲聊，只保留主人声音</div>
          </div>
          <span class="m3-switch">
            <input type="checkbox" id="cfg_enableTargetSpeakerExtraction" onchange="scheduleAutoSave(true)">
            <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
          </span>
        </label>
        <div class="slider-row" style="margin-top:8px;">
          <span class="slider-label">TSE 干扰人声抑制强度: <span id="lbl_tseAttenuationDb">20 dB</span></span>
          <input type="range" class="m3-slider" id="cfg_tseAttenuationDb" min="10" max="30" step="1" oninput="updateSliderLabel('tseAttenuationDb', Math.round(this.value)+' dB'); scheduleAutoSave();">
        </div>
        <div style="font-size:11px;color:var(--fg-sub);margin-bottom:8px;">衰减电视音与路人人声的强度（推荐 18~24 dB）</div>
        <hr class="card-divider">
        <div style="padding:10px 12px;border-radius:8px;background:var(--fill);margin-bottom:10px;">
          <div style="display:flex;align-items:center;gap:6px;font-weight:600;font-size:13px;">
            <span>已录入主人声纹: <strong id="lbl_speakerEnrolledCount">0</strong> / 5 个样本</span>
          </div>
          <div style="font-size:12px;color:var(--fg-sub);margin-top:2px;">
            声纹模型: <span id="lbl_speakerModelName">未加载</span>
          </div>
          <div id="lbl_speakerDomainHint" style="font-size:12px;color:var(--fg-sub);margin-top:2px;"></div>
          <div id="lbl_speakerStale" style="display:none;font-size:12px;color:var(--danger);margin-top:2px;"></div>
          <div style="font-size:12px;color:var(--fg-sub);margin-top:2px;">
            提示：可多次录入不同距离/语速的样本文本（推荐录制“小曼小曼，今天天气怎么样”），多样本融合能显著提升识别率。
          </div>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <button class="btn-filled" id="btnEnrollSpeaker" onclick="enrollSpeakerSample()">录入当前说话声音为样本</button>
          <button class="btn-outlined" id="btnTestSpeaker" onclick="testSpeakerSample()">测试最新声音相似度</button>
          <button class="btn-text" style="color:var(--error);" onclick="clearSpeakerProfile()">清空声纹</button>
        </div>
        <div id="speakerTestResult" style="font-size:13px;font-weight:700;margin-top:8px;"></div>
        <div id="speakerScorePanel" style="display:none;margin-top:10px;padding:12px;border-radius:10px;border:1px solid rgba(128,128,128,.35);background:var(--fill);">
          <div style="display:flex;align-items:baseline;gap:8px;">
            <span id="speakerScorePercent" style="font-size:30px;font-weight:800;line-height:1;">0.0%</span>
            <span id="speakerScoreVerdict" style="font-size:13px;font-weight:700;"></span>
          </div>
          <div style="height:10px;border-radius:5px;background:rgba(128,128,128,.25);overflow:hidden;margin-top:8px;">
            <div id="speakerScoreFill" style="height:100%;width:0%;border-radius:5px;transition:width .35s ease;"></div>
          </div>
          <div id="speakerScoreMeta" style="font-size:12px;color:var(--fg-sub);margin-top:8px;"></div>
          <div id="speakerScoreSamples" style="font-size:12px;color:var(--fg-sub);margin-top:4px;"></div>
        </div>
      </div>
    </div>

    <!-- 3. 大语言模型（OpenAI 兼容） -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M13 8.57c-.79 0-1.43.64-1.43 1.43s.64 1.43 1.43 1.43 1.43-.64 1.43-1.43-.64-1.43-1.43-1.43zM13 3C9.25 3 6.2 5.94 6.02 9.64L4.1 12.2C3.85 12.53 4.09 13 4.5 13H6v3c0 1.1.9 2 2 2h1v3h7v-4.68c2.36-1.12 4-3.53 4-6.32 0-3.87-3.13-7-7-7z"/></svg>
      <h3 id="llmSectionHeaderTitle">大语言模型（OpenAI 兼容）</h3>
    </div>
    <div class="settings-card">
      <div id="cascadeOpenAiFieldsGroup">
        <div class="field-group">
          <label class="field-label">API Base URL</label>
          <input type="text" class="m3-input" id="cfg_openAiBaseUrl" oninput="scheduleAutoSave()">
        </div>
        <div class="field-group" style="margin-top:8px;">
          <label class="field-label">API Key</label>
          <input type="password" class="m3-input" id="cfg_openAiApiKey" oninput="scheduleAutoSave()">
        </div>
        <div class="field-group" style="margin-top:8px;">
          <label class="field-label" id="modelFieldLabel">模型名称</label>
          <div style="display:flex;gap:8px;align-items:center;">
            <select class="m3-select" id="cfg_openAiModelSelect" style="flex:1;" onchange="onModelSelectChanged(this.value)"></select>
            <input type="text" class="m3-input" id="cfg_openAiModel" style="flex:1;display:none;" oninput="scheduleAutoSave()">
            <button class="icon-btn tonal" title="从 API 拉取/刷新可用模型列表" onclick="fetchAvailableModels()">
              <svg class="ic-sm" viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
            </button>
            <button class="icon-btn outlined" title="切换下拉/手动输入" onclick="toggleManualModelInput()">
              <svg class="ic-sm" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a.996.996 0 0 0 0-1.41l-2.34-2.34a.996.996 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
            </button>
          </div>
        </div>
        <label class="switch-row" style="margin-top:8px;">
          <span class="switch-row-title">关闭大模型深度思考</span>
          <span class="m3-switch">
            <input type="checkbox" id="cfg_disableThinking" onchange="scheduleAutoSave(true)">
            <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
          </span>
        </label>
      </div>
      <label class="switch-row">
        <span class="switch-row-title">启用联网搜索 (web_search)</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableWebSearch" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <label class="switch-row">
        <span class="switch-row-title">启用外部 Agent (OpenCode / Hermes) 与受限 CLI 工具</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableOpenCode" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <div class="field-group">
        <label class="field-label">外部编码 Agent 引擎 (二选一)</label>
        <select class="m3-select" id="cfg_codeAgentProvider" onchange="updateCodeAgentProviderUI(); scheduleAutoSave(true)">
          <option value="opencode">OpenCode (默认)</option>
          <option value="hermes">Hermes Agent</option>
        </select>
      </div>
      <div class="field-group" id="openCodeCmdGroup">
        <label class="field-label">OpenCode 命令路径</label>
        <input type="text" class="m3-input" id="cfg_openCodeCommand" placeholder="opencode" oninput="scheduleAutoSave()">
      </div>
      <div class="field-group" id="hermesCmdGroup" style="display:none;">
        <label class="field-label">Hermes 命令路径</label>
        <input type="text" class="m3-input" id="cfg_hermesCommand" placeholder="hermes" oninput="scheduleAutoSave()">
      </div>
      <div class="field-group">
        <label class="field-label">进度报告间隔（秒，默认 15）</label>
        <input type="number" class="m3-input" id="cfg_openCodeProgressIntervalSeconds" min="1" max="600" oninput="scheduleAutoSave()">
      </div>
      <div class="field-group">
        <label class="field-label">最大超时（秒，0 表示无限等待）</label>
        <input type="number" class="m3-input" id="cfg_openCodeTimeoutSeconds" min="0" max="600" oninput="scheduleAutoSave()">
      </div>
      <div class="field-group">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;">
          <label class="field-label" style="margin:0;">已安装自定义持久化工具</label>
          <button class="icon-btn tonal" style="width:28px;height:28px;" title="刷新工具列表" onclick="loadCustomTools()">
            <svg class="ic-sm" viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
          </button>
        </div>
        <div id="customToolsList" style="display:flex;flex-direction:column;gap:6px;"></div>
      </div>
      <div class="field-group">
        <label class="field-label">系统提示词</label>
        <textarea class="m3-textarea" id="cfg_systemPrompt" rows="4" oninput="scheduleAutoSave()"></textarea>
      </div>
      <div class="field-group">
        <label class="field-label">当前地理位置（Android 自动定位，失败时使用此地址）</label>
        <input type="text" class="m3-input" id="cfg_locationAddress" oninput="scheduleAutoSave()">
      </div>
    </div>

    <!-- 4. 语音合成与交互选项 -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>
      <h3>语音合成与交互选项</h3>
    </div>
    <div class="settings-card">
      <label class="switch-row">
        <span class="switch-row-title">启用 TTS 自动播放</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableTtsPlayback" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <label class="switch-row">
        <span class="switch-row-title">支持语音打断（Barge-in）</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableBargeIn" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <label class="switch-row">
        <span class="switch-row-title">交互反馈提示音（轻滴声）</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enablePromptTone" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>

      <!-- 服务器播放音量调节 -->
      <div class="slider-row">
        <span class="slider-label">服务器播放音量: <span id="lbl_playbackVolume">80%</span></span>
        <input type="range" class="m3-slider" id="cfg_playbackVolume" min="0" max="100" step="1" oninput="onVolumeSliderInput(this.value)" onchange="commitVolumeChange(this.value)">
      </div>

      <div class="slider-row">
        <span class="slider-label">朗读语速: <span id="lbl_ttsSpeed">1.0x</span></span>
        <input type="range" class="m3-slider" id="cfg_ttsSpeed" min="0.5" max="2.0" step="0.1" oninput="updateSliderLabel('ttsSpeed', Number(this.value).toFixed(1)+'x'); scheduleAutoSave();">
      </div>

      <hr class="card-divider">

      <div class="field-group">
        <label class="field-label">服务器扬声器输出设备</label>
        <select class="m3-select" id="cfg_audioOutputDeviceId" onchange="scheduleAutoSave(true)"></select>
      </div>

      <div class="field-group">
        <label class="field-label">TTS 语音合成引擎</label>
        <select class="m3-select" id="cfg_ttsEngine" onchange="scheduleAutoSave(true)">
          <option value="edge">微软 Edge Neural (超自然高品质 · 推荐)</option>
          <option value="system">系统原生离线 TTS 引擎 (espeak-ng)</option>
        </select>
      </div>

      <div class="field-group" id="edgeVoiceGroup">
        <label class="field-label">微软神经网络音色</label>
        <select class="m3-select" id="cfg_edgeVoice" onchange="scheduleAutoSave(true)">
          <option value="zh-CN-XiaoxiaoNeural">晓晓 (温柔自然女声 · 推荐)</option>
          <option value="zh-CN-YunxiNeural">云希 (阳光沉稳男声)</option>
          <option value="zh-CN-XiaoyiNeural">小艺 (活泼亲切女声)</option>
          <option value="zh-CN-YunjianNeural">云健 (影视解说/磁性男声)</option>
          <option value="zh-CN-YunyangNeural">云扬 (专业新闻播音男声)</option>
        </select>
        <div style="display:flex;justify-content:flex-end;margin-top:6px;">
          <button class="btn-outlined" id="previewVoiceBtn" onclick="previewServerVoice()">试听当前音色</button>
        </div>
      </div>
    </div>

    <!-- 5. 摄像头与大模型视觉拍照（工具调用） -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M20 4h-3.17L15 2H9L7.17 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-8 13c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5z"/></svg>
      <h3>摄像头与大模型视觉拍照（工具调用）</h3>
    </div>
    <div class="settings-card">
      <label class="switch-row">
        <div>
          <span class="switch-row-title">启用大模型相机拍照能力</span>
          <div style="font-size:12px;color:var(--fg-sub);">大模型可自主调用 capture_photo 工具拍摄现场画面并结合视觉理解回答</div>
        </div>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_enableVisionIntent" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <div class="field-group">
        <div style="display:flex;align-items:center;justify-content:space-between;">
          <label class="field-label">本地 V4L2 摄像头设备</label>
          <button class="btn-text" onclick="testCameraCapture()">拍照测试</button>
        </div>
        <select class="m3-select" id="cfg_linuxCameraDevice" onchange="scheduleAutoSave(true)"></select>
        <div id="cameraTestPreview" style="margin-top:6px;"></div>
      </div>
      <div class="field-group">
        <label class="field-label">发送前压缩</label>
        <select class="m3-select" id="cfg_cameraSendShortEdge" onchange="scheduleAutoSave(true)">
          <option value="480">480p</option>
          <option value="720">720p</option>
          <option value="1080">1080p</option>
        </select>
      </div>
      <div class="slider-row">
        <span class="slider-label">空闲关闭: <span id="lbl_cameraKeepAliveMinutes">2 分钟</span></span>
        <input type="range" class="m3-slider" id="cfg_cameraKeepAliveMinutes" min="0" max="10" step="1" oninput="updateSliderLabel('cameraKeepAliveMinutes', this.value+' 分钟'); scheduleAutoSave();">
      </div>
    </div>

    <!-- 7. Linux 服务器与全链路诊断 -->
    <div class="section-header">
      <svg class="ic-sm" viewBox="0 0 24 24"><path d="M20 13H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1v-6c0-.55-.45-1-1-1zM7 19c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zM20 3H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1V4c0-.55-.45-1-1-1zM7 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z"/></svg>
      <h3>Linux 服务器与全链路诊断</h3>
    </div>
    <div class="settings-card" style="margin-bottom:40px;">
      <label class="switch-row">
        <span class="switch-row-title">服务启动时自动开启麦克风常驻监听</span>
        <span class="m3-switch">
          <input type="checkbox" id="cfg_autoStartMicOnLaunch" onchange="scheduleAutoSave(true)">
          <span class="m3-switch-track"><span class="m3-switch-thumb"></span></span>
        </span>
      </label>
      <div class="field-group">
        <label class="field-label">Web 控制台访问密码（留空则局域网免密）</label>
        <input type="password" class="m3-input" id="cfg_webAccessPassword" placeholder="留空免密访问" oninput="scheduleAutoSave()">
      </div>
      <hr class="card-divider">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
        <span style="font-size:14px;font-weight:600;">6 步全链路运行态自动化诊断测试</span>
        <button class="btn-filled" id="selfTestBtn" onclick="runDiagnosticSelfTest()">开始全链路诊断</button>
      </div>
      <div class="mono-log" id="selfTestLogBox" style="display:none;"></div>
    </div>
  </div>
</section>

<!-- ==================== 模态对话框：重命名对话 ==================== -->
<div class="modal-backdrop" id="renameModal">
  <div class="alert-dialog">
    <div class="alert-dialog-title">重命名对话</div>
    <input type="text" class="m3-input" id="renameSessionInput" maxlength="40" placeholder="请输入新的对话标题">
    <div class="alert-dialog-actions">
      <button class="btn-text" onclick="closeRenameModal()">取消</button>
      <button class="btn-filled" onclick="confirmRenameSession()">保存</button>
    </div>
  </div>
</div>

<!-- ==================== 模态对话框：清空全部历史确认 ==================== -->
<div class="modal-backdrop" id="clearAllModal">
  <div class="alert-dialog">
    <div class="alert-dialog-title">清空全部历史对话</div>
    <div class="alert-dialog-content">确定要删除所有历史对话及关联图片吗？此操作无法撤销。</div>
    <div class="alert-dialog-actions">
      <button class="btn-text" onclick="closeClearAllDialog()">取消</button>
      <button class="btn-filled danger" onclick="confirmClearAllHistory()">清空</button>
    </div>
  </div>
</div>

<!-- ==================== 模态对话框：访问密码鉴权 ==================== -->
<div class="modal-backdrop" id="authModal">
  <div class="alert-dialog">
    <div class="alert-dialog-title">输入访问密码</div>
    <div class="alert-dialog-content">该服务器已启用访问密码保护，请输入密码继续：</div>
    <input type="password" class="m3-input" id="authPasswordInput" placeholder="访问密码" onkeydown="if(event.key==='Enter') submitAuthPassword()">
    <div class="alert-dialog-actions">
      <button class="btn-filled" onclick="submitAuthPassword()">解锁</button>
    </div>
  </div>
</div>

<!-- ==================== 全屏图片查看器 ==================== -->
<div class="modal-backdrop" id="imageViewerModal" style="background:rgba(0,0,0,0.88);" onclick="closeImageViewer()">
  <img id="imageViewerImg" src="" style="max-width:92vw;max-height:90vh;border-radius:12px;object-fit:contain;">
</div>

<!-- ==================== SnackBar ==================== -->
<div class="snackbar" id="snackbar"></div>

<script>
let accessPassword = localStorage.getItem('sa_web_password') || '';
let appState = {};
let currentSettings = {};
let availableModels = [];
let isManualModelInput = false;
let hardwareDevices = { inputDevices: [], outputDevices: [], cameraDevices: [] };
let eventSource = null;
let autoSaveTimer = null;
let renamingSessionId = '';
let lastRenderedMessagesSig = '';

// 主题初始化（跟随系统或本地记忆）
(function initTheme() {
  const saved = localStorage.getItem('sa_theme');
  if (saved === 'dark' || (!saved && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.setAttribute('data-theme', 'dark');
  }
})();

function toggleTheme() {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  if (isDark) {
    document.documentElement.removeAttribute('data-theme');
    localStorage.setItem('sa_theme', 'light');
  } else {
    document.documentElement.setAttribute('data-theme', 'dark');
    localStorage.setItem('sa_theme', 'dark');
  }
}

function showSnackbar(msg) {
  const el = document.getElementById('snackbar');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.remove('show'), 2800);
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function apiFetch(url, options = {}) {
  const headers = Object.assign({ 'Content-Type': 'application/json' }, options.headers || {});
  if (accessPassword) headers['X-Access-Password'] = accessPassword;
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    document.getElementById('authModal').classList.add('open');
    throw new Error('Unauthorized');
  }
  return res;
}

function submitAuthPassword() {
  accessPassword = document.getElementById('authPasswordInput').value.trim();
  localStorage.setItem('sa_web_password', accessPassword);
  document.getElementById('authModal').classList.remove('open');
  initApp();
}

// ==================== SSE 与实时状态渲染 ====================
function connectSse() {
  if (eventSource) {
    try { eventSource.close(); } catch (_) {}
  }
  const tokenParam = accessPassword ? ('?token=' + encodeURIComponent(accessPassword)) : '';
  eventSource = new EventSource('/api/events' + tokenParam);
  eventSource.onmessage = (ev) => {
    try {
      const data = JSON.parse(ev.data);
      applyState(data);
    } catch (_) {}
  };
  eventSource.onerror = () => {
    setTimeout(connectSse, 3000);
  };
}

function applyState(s) {
  appState = s || {};
  renderTopBarAndStatusPill(appState);
  renderSpeakerDomainHint(appState);
  renderChatMessages(appState);
  renderDrawerSessions();
  renderMicTestLiveState(appState);
  if (typeof appState.playbackVolume === 'number') {
    syncVolumeUi(appState.playbackVolume);
  }
  if (Array.isArray(appState.selfTestLogs) && appState.selfTestLogs.length > 0) {
    const logBox = document.getElementById('selfTestLogBox');
    logBox.style.display = 'block';
    logBox.textContent = appState.selfTestLogs.join('\n');
    logBox.scrollTop = logBox.scrollHeight;
  }
}

// 声纹模板按音源域分组后，明确提示「当前音源是否已有专属模板」。
// 换到 8kHz 蓝牙窄带却只有宽带模板时，本人分数会被压低，必须补录。
function renderSpeakerDomainHint(s) {
  const el = document.getElementById('lbl_speakerDomainHint');
  if (!el) return;
  const domain = s.speakerAcousticDomain || 'wideband';
  const counts = s.speakerDomainCounts || {};
  const own = counts[domain] || 0;
  const total = (counts.wideband || 0) + (counts.narrowband || 0);
  const label = domain === 'narrowband' ? '蓝牙窄带 (8kHz)' : '内置 / 宽带 (16kHz)';
  if (own === 0) {
    el.style.color = 'var(--danger)';
    el.textContent = '当前音源：' + label + ' — 本音源域还没有专属声纹模板，请用当前麦克风补录 3~5 条（旧域 ' + total + ' 条已保留，切回时可直接复用）。';
  } else {
    el.style.color = 'var(--fg-sub)';
    el.textContent = '当前音源：' + label + ' — 已匹配 ' + own + ' 条专属模板；其它音源域 ' + (total - own) + ' 条保留。';
  }
}

function renderTopBarAndStatusPill(s) {
  // 话筒按钮状态与图标
  const micBtn = document.getElementById('micToggleBtn');
  const micIcon = document.getElementById('micToggleIcon');
  if (s.isMicListening) {
    micBtn.className = 'icon-btn accent';
    micBtn.title = '话筒监听中（点击静音）';
    if (micIcon) {
      micIcon.innerHTML = '<path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/>';
    }
  } else {
    micBtn.className = 'icon-btn muted';
    micBtn.title = '话筒已静音（点击开启）';
    if (micIcon) {
      micIcon.innerHTML = '<path d="M19 11h-1.7c0 .74-.16 1.43-.43 2.05l1.23 1.23c.56-.98.9-2.09.9-3.28zm-4.02.17c0-.06.02-.11.02-.17V5c0-1.66-1.34-3-3-3S9 3.34 9 5v.18l5.98 5.99zM4.27 3L3 4.27l6.01 6.01V11c0 1.66 1.33 3 2.99 3 .22 0 .44-.03.65-.08l1.66 1.66c-.71.33-1.5.52-2.31.52-2.76 0-5.3-2.1-5.3-5.1H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c.91-.13 1.77-.45 2.54-.9L19.73 21 21 19.73 4.27 3z"/>';
    }
  }

  // 音源类型：内置 / 蓝牙 / 外接（8kHz 蓝牙 HFP 链路排障时一眼可辨）
  const kind = s.audioInputDeviceKind || 'unknown';
  const kindLabel = s.audioInputDeviceKindLabel || '';
  const device = s.audioInputDevice || '';
  micBtn.classList.toggle('bt-source', kind === 'bluetooth');
  micBtn.classList.toggle('ext-source', kind === 'external');
  const badge = document.getElementById('micSourceBadge');
  const badgeText = { bluetooth: 'BT', builtIn: '内置', external: '外接' }[kind];
  if (badge) {
    if (badgeText) {
      badge.hidden = false;
      badge.className = 'mic-source-badge k-' + kind;
      badge.textContent = badgeText;
    } else {
      badge.hidden = true;
      badge.textContent = '';
    }
  }
  micBtn.title = (s.isMicListening ? '话筒监听中（点击静音）' : '话筒已静音（点击开启）')
    + (kindLabel ? '\n' + kindLabel : '')
    + (device ? ' · ' + device : '');

  // 底部手动录音按钮
  const recBtn = document.getElementById('micRecordBtn');
  const recIcon = document.getElementById('micRecordIcon');
  if (s.isManualRecording) {
    recBtn.className = 'circle-action-btn mic-btn recording';
    recBtn.title = '停止录音并直接发送';
    recIcon.innerHTML = '<path d="M6 6h12v12H6z"/>';
  } else {
    recBtn.className = 'circle-action-btn mic-btn' + (s.isMicListening ? ' listening' : '');
    recBtn.title = '点按对讲录音（直接发送，免唤醒词）';
    recIcon.innerHTML = '<path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c-.49 0-.9.36-.98.85C16.52 14.2 14.47 16 12 16s-4.52-1.8-4.93-4.15c-.08-.49-.49-.85-.98-.85-.61 0-1.09.54-1 1.14.49 3 2.89 5.35 5.91 5.78V20c0 .55.45 1 1 1s1-.45 1-1v-2.08c3.02-.43 5.42-2.78 5.91-5.78.1-.6-.39-1.14-1-1.14z"/>';
  }

  // 顶部动态状态胶囊 (_buildStatusPill)
  const pill = document.getElementById('statusPill');
  const titleEl = document.getElementById('statusPillTitle');
  const textEl = document.getElementById('statusPillText');
  const badgeEl = document.getElementById('statusPillBadge');
  const stopBtn = document.getElementById('statusPillStopBtn');

  pill.className = 'status-pill' + (!s.isMicListening ? ' clickable' : '');
  if (s.status === 'listeningContent' || s.status === 'playing') {
    pill.classList.add('state-active');
  } else if (s.status === 'thinking') {
    pill.classList.add('state-thinking');
  }

  const titleMap = {
    idle: '低功耗待机中',
    listeningContent: '正在倾听指令',
    thinking: '大模型思考中',
    playing: '正在语音朗读'
  };
  titleEl.textContent = titleMap[s.status] || '低功耗待机中';

  const displaySpeech = (s.displayTranscript || '').trim();
  if (s.isMicTesting && (s.micTestText || '').trim()) {
    textEl.innerHTML = '<strong style="color:var(--accent);">[测麦识别] </strong>' + escapeHtml(s.micTestText);
    badgeEl.style.display = 'inline-block';
    badgeEl.className = 'status-pill-badge matched';
    badgeEl.textContent = '测麦模式';
  } else if (displaySpeech) {
    const matched = !!s.isWakeWordMatched;
    const prefixColor = matched ? 'var(--accent)' : 'var(--fg-sub)';
    const prefixText = matched ? '已命中: ' : '未匹配: ';
    textEl.innerHTML = '<strong style="color:' + prefixColor + ';">' + prefixText + '</strong>' + escapeHtml(displaySpeech);
    badgeEl.style.display = 'inline-block';
    badgeEl.className = 'status-pill-badge ' + (matched ? 'matched' : 'unmatched');
    badgeEl.textContent = matched ? '已激活' : '未触发';
  } else {
    textEl.textContent = s.isMicTesting
      ? '麦克风测试中：请对着服务器麦克风说话...'
      : (s.statusHint || '');
    badgeEl.style.display = 'none';
  }

  stopBtn.style.display = (s.status === 'playing') ? 'inline-flex' : 'none';

  // 顶部迷你音量计
  const miniVolWrap = document.getElementById('miniVolWrap');
  if (s.isMicListening) {
    miniVolWrap.style.display = 'inline-flex';
    const pct = Math.round((s.micLevel || 0) * 100);
    document.getElementById('miniVolLabel').textContent = pct + '%';
    const thresholds = [8, 22, 40, 60, 80];
    for (let i = 0; i < 5; i++) {
      const bar = document.getElementById('mvBar' + (i + 1));
      if (pct >= thresholds[i] || (i === 0 && s.vadDetected)) {
        bar.classList.add('lit');
      } else {
        bar.classList.remove('lit');
      }
    }
  } else {
    miniVolWrap.style.display = 'none';
  }

  // 顶部服务器实时 CPU 占用率指标
  const miniCpuWrap = document.getElementById('miniCpuWrap');
  const miniCpuLabel = document.getElementById('miniCpuLabel');
  if (miniCpuWrap && miniCpuLabel) {
    if (typeof s.cpuUsage === 'number' && !isNaN(s.cpuUsage)) {
      miniCpuWrap.style.display = 'inline-flex';
      const cpuVal = Math.round(s.cpuUsage);
      miniCpuLabel.textContent = 'CPU ' + cpuVal + '%';
      if (cpuVal >= 85) {
        miniCpuWrap.classList.add('high');
      } else {
        miniCpuWrap.classList.remove('high');
      }
    } else {
      miniCpuLabel.textContent = 'CPU --%';
    }
  }
}

function onStatusPillClick() {
  if (!appState.isMicListening) {
    toggleMic();
  }
}

function onStartWordModeChange() {
  const modeEl = document.getElementById('cfg_startWordMode');
  if (!modeEl) return;
  const m = modeEl.value;
  const desc = document.getElementById('desc_startWordMode');
  const grp = document.getElementById('group_continuousTimeout');
  if (desc) {
    desc.textContent = m === 'auto'
      ? '自动模式：默认需说开始词唤醒；唤醒后进入连续对话，无需重复说开始词；无对话超时或说“结束对话/停止对话”退出。'
      : (m === 'enabled'
          ? '启用模式：每次发起提问或交互前，均需先说开始词唤醒。'
          : '关闭模式：待机状态下无需说开始词，随时直接说话即可发起交互。');
  }
  if (grp) {
    grp.style.display = m === 'auto' ? 'block' : 'none';
  }
}

// ==================== 消息列表渲染 (_buildMessageBubble) ====================
function renderMarkdown(raw) {
  let text = String(raw || '');
  let thinkHtml = '';
  const thinkMatch = text.match(/<think>([\s\S]*?)(?:<\/think>|$)/i);
  if (thinkMatch) {
    const thinkContent = thinkMatch[1].trim();
    text = text.replace(thinkMatch[0], '').trim();
    if (thinkContent) {
      thinkHtml = '<details class="think-details"><summary>思考过程</summary><div class="think-body">' + escapeHtml(thinkContent) + '</div></details>';
    }
  }
  let html = escapeHtml(text);
  // 代码块
  html = html.replace(/```([a-zA-Z0-9_-]*)\n([\s\S]*?)```/g, (_, lang, code) => {
    return '<pre><code>' + code + '</code></pre>';
  });
  // 行内代码
  html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');
  // 标题
  html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
  // 粗体
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  // 换行转段落
  const paragraphs = html.split(/\n{2,}/).map(p => '<p>' + p.replace(/\n/g, '<br>') + '</p>').join('');
  return thinkHtml + '<div class="md-body">' + (paragraphs || '...') + '</div>';
}

function renderChatMessages(s) {
  const list = document.getElementById('chatList');
  const msgs = s.messages || [];
  const sig = JSON.stringify(msgs.map(m => [m.id, m.role, (m.content || '').length, m.imagePath, m.isUnintended ? '1' : '0'])) + '|' + (s.startWords || []).join(',');
  if (sig === lastRenderedMessagesSig) return;
  lastRenderedMessagesSig = sig;

  if (msgs.length === 0) {
    const startW = (s.startWords && s.startWords.length) ? s.startWords.join('、') : '晓漫';
    list.innerHTML =
      '<div class="empty-state">' +
        '<svg class="ic-lg" viewBox="0 0 24 24"><path d="M7 18h2V6H7v12zm4 4h2V2h-2v20zm-8-8h2v-4H3v4zm12 4h2V6h-2v12zm4-8v4h2v-4h-2z"/></svg>' +
        '<div class="empty-state-title">随身助理已就绪</div>' +
        '<div class="empty-state-sub">' +
          '你可以随时呼唤「' + escapeHtml(startW) + '」开始对话，系统将由大模型智能理解对话意图与连续交互。' +
        '</div>' +
      '</div>';
    return;
  }

  let html = '';
  for (const m of msgs) {
    const isUser = m.role === 'user';
    let imgHtml = '';
    if (m.imagePath) {
      const tokenParam = accessPassword ? ('&token=' + encodeURIComponent(accessPassword)) : '';
      const imgUrl = '/api/image?msgId=' + encodeURIComponent(m.id || '') + '&path=' + encodeURIComponent(m.imagePath) + tokenParam;
      imgHtml =
        '<div><div class="msg-img-wrap" onclick="openImageViewer(\'' + imgUrl + '\')">' +
          '<img src="' + imgUrl + '" alt="已捕获画面">' +
          '<span class="msg-img-zoom"><svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14zm2.5-4h-2v2H9v-2H7V9h2V7h1v2h2v1z"/></svg></span>' +
        '</div></div>';
    }
    const rawContent = m.content || '...';
    if (m.isUnintended) {
      html += '<div class="msg-unintended-row"><div class="msg-unintended-bubble"><div class="unintended-badge">无交谈意图 · 背景信息</div><div class="unintended-text">' + escapeHtml(rawContent) + '</div></div></div>';
    } else if (isUser) {
      html += '<div class="msg-user-row"><div class="msg-user-bubble">' + imgHtml + escapeHtml(rawContent) + '</div></div>';
    } else {
      html += '<div class="msg-assistant-row">' + imgHtml + renderMarkdown(rawContent) + '</div>';
    }
  }
  list.innerHTML = html;
  list.scrollTop = list.scrollHeight;
}

function renderMicTestSpeakerBadge(item) {
  if (item.similarityPercent != null) {
    const isMatched = !!item.speakerMatched;
    const cls = isMatched ? 'badge-matched' : 'badge-unmatched';
    const label = (isMatched ? '🟢 声纹相似度 ' : '⚠️ 声纹相似度 ') + item.similarityPercent + '% (' + (isMatched ? '匹配' : '未达标') + ')';
    return '<span class="mic-badge ' + cls + '" title="声纹相似度 ' + item.similarityPercent + '%">' + escapeHtml(label) + '</span>';
  }
  if (item.speakerStatus) {
    return '<span class="mic-badge badge-neutral">' + escapeHtml(item.speakerStatus) + '</span>';
  }
  return '';
}

function renderMicTestLlmBadge(item) {
  if (item.shouldReply === true) {
    const intentHint = item.intent ? ' (' + escapeHtml(item.intent) + ')' : '';
    return '<span class="mic-badge badge-reply" title="' + escapeHtml(item.detail || '大模型判定需回答') + '">💬 大模型认为需回答' + intentHint + '</span>';
  }
  if (item.shouldReply === false) {
    if (item.llmDecision === '测试模式') {
      return '<span class="mic-badge badge-neutral" title="麦克风测试模式，不触发大模型">🛠️ 测试模式 (未发大模型)</span>';
    }
    if (item.llmDecision === '待机未唤醒') {
      return '<span class="mic-badge badge-muted" title="' + escapeHtml(item.detail || '待机状态未命中唤醒词') + '">💤 待机未唤醒</span>';
    }
    if (item.llmDecision === '声纹拦截') {
      return '<span class="mic-badge badge-unmatched" title="' + escapeHtml(item.detail || '声纹不匹配已拦截') + '">🚫 声纹拦截已忽略</span>';
    }
    if (item.llmDecision === '外放回声已丢弃') {
      return '<span class="mic-badge badge-muted" title="疑似外放回声已丢弃">🔇 回声丢弃</span>';
    }
    const intentHint = item.intent ? ' (' + escapeHtml(item.intent) + ')' : '';
    return '<span class="mic-badge badge-muted" title="' + escapeHtml(item.detail || '大模型判定无需回答') + '">🔇 大模型认为无需回答' + intentHint + '</span>';
  }
  if (item.llmDecision) {
    const isThinking = item.llmDecision.includes('判定中') || item.llmDecision.includes('思考中') || item.llmDecision.includes('请求中');
    const cls = isThinking ? 'badge-info' : 'badge-neutral';
    return '<span class="mic-badge ' + cls + '" title="' + escapeHtml(item.detail || '') + '">' + escapeHtml(item.llmDecision) + '</span>';
  }
  return '';
}

// ==================== 麦克风实时测试面板更新 ====================
function renderMicTestLiveState(s) {
  const pct = Math.round((s.micLevel || 0) * 100);
  const dbfs = typeof s.micDbfs === 'number' ? s.micDbfs.toFixed(1) : '-60.0';
  const vad = !!s.vadDetected;

  const pctEl = document.getElementById('micTestVolPercent');
  const dbEl = document.getElementById('micTestDbfs');
  const fillEl = document.getElementById('micTestVolFill');
  const vadBadge = document.getElementById('micTestVadBadge');
  const toggleBtn = document.getElementById('micTestToggleBtn');
  const latestTextEl = document.getElementById('micTestLatestText');
  const latestBadgesEl = document.getElementById('micTestLatestBadges');
  const historyEl = document.getElementById('micTestHistoryList');

  if (pctEl) pctEl.textContent = pct + '%';
  if (dbEl) dbEl.textContent = dbfs + ' dB';
  if (fillEl) fillEl.style.width = pct + '%';

  if (vadBadge) {
    if (!s.isMicListening) {
      vadBadge.textContent = '话筒已静音';
      vadBadge.style.background = 'var(--fill)';
      vadBadge.style.color = 'var(--fg-sub)';
    } else if (vad) {
      vadBadge.textContent = '🟢 检测到语音输入';
      vadBadge.style.background = 'rgba(0, 137, 123, 0.2)';
      vadBadge.style.color = 'var(--accent)';
    } else {
      vadBadge.textContent = '监听中（静音）';
      vadBadge.style.background = 'var(--fill)';
      vadBadge.style.color = 'var(--fg-sub)';
    }
  }

  if (toggleBtn) {
    if (s.isMicTesting) {
      toggleBtn.textContent = '停止麦克风测试';
      toggleBtn.className = 'btn-filled danger';
    } else {
      toggleBtn.textContent = '开始麦克风测试';
      toggleBtn.className = 'btn-filled accent-bg';
    }
  }

  const latest = (s.micTestText || s.displayTranscript || '').trim();
  if (latestTextEl) {
    latestTextEl.textContent = latest || (s.isMicListening ? '正在监听，请对着服务器麦克风说话...' : '请点击「开始麦克风测试」或开启话筒监听');
  }

  if (latestBadgesEl) {
    if (Array.isArray(s.micTestHistory) && s.micTestHistory.length > 0) {
      const top = s.micTestHistory[0];
      const spk = renderMicTestSpeakerBadge(top);
      const llm = renderMicTestLlmBadge(top);
      latestBadgesEl.innerHTML = spk + llm;
      latestBadgesEl.style.display = (spk || llm) ? 'flex' : 'none';
    } else {
      latestBadgesEl.innerHTML = '';
      latestBadgesEl.style.display = 'none';
    }
  }

  if (historyEl && Array.isArray(s.micTestHistory)) {
    if (s.micTestHistory.length === 0) {
      historyEl.innerHTML = '';
    } else {
      historyEl.innerHTML = s.micTestHistory.map(item => {
        const speakerBadge = renderMicTestSpeakerBadge(item);
        const llmBadge = renderMicTestLlmBadge(item);
        const hasBadges = speakerBadge || llmBadge;
        return '<div class="mic-test-item">' +
          '<div class="mic-test-header">' +
            '<span class="mic-test-text">' + escapeHtml(item.text) + '</span>' +
            '<span class="mic-test-meta">' +
              escapeHtml(item.time) + (item.durationMs ? (' · ' + item.durationMs + 'ms') : '') +
            '</span>' +
          '</div>' +
          (hasBadges ? ('<div class="mic-test-tags">' + speakerBadge + llmBadge + '</div>') : '') +
        '</div>';
      }).join('');
    }
  }
}

async function toggleMicTestMode() {
  const target = !appState.isMicTesting;
  await apiFetch('/api/mic-test', {
    method: 'POST',
    body: JSON.stringify({ enabled: target })
  });
  showSnackbar(target ? '已开启麦克风测试模式（说话仅识别文字，不触发对话）' : '已退出麦克风测试模式');
}

async function clearMicTestHistory() {
  await apiFetch('/api/mic-test', {
    method: 'POST',
    body: JSON.stringify({ enabled: !!appState.isMicTesting, clear: true })
  });
}

function openMicTestInSettings() {
  document.getElementById('volumePopover').classList.remove('open');
  openSettingsScreen();
  setTimeout(() => {
    const panel = document.getElementById('micTestPanel');
    if (panel) panel.scrollIntoView({ behavior: 'smooth', block: 'center' });
    if (!appState.isMicTesting) {
      toggleMicTestMode();
    }
  }, 120);
}

// ==================== 服务器音量控制 ====================
function syncVolumeUi(vol) {
  const v = Math.max(0, Math.min(100, Math.round(vol)));
  const popSlider = document.getElementById('popoverVolSlider');
  const popLbl = document.getElementById('popoverVolLabel');
  const cfgSlider = document.getElementById('cfg_playbackVolume');
  const cfgLbl = document.getElementById('lbl_playbackVolume');
  if (popSlider && document.activeElement !== popSlider) popSlider.value = v;
  if (popLbl) popLbl.textContent = v + '%';
  if (cfgSlider && document.activeElement !== cfgSlider) cfgSlider.value = v;
  if (cfgLbl) cfgLbl.textContent = v + '%';
}

function onVolumeSliderInput(val) {
  const v = Math.round(Number(val));
  document.getElementById('popoverVolLabel').textContent = v + '%';
  document.getElementById('lbl_playbackVolume').textContent = v + '%';
  document.getElementById('popoverVolSlider').value = v;
  document.getElementById('cfg_playbackVolume').value = v;
}

async function commitVolumeChange(val) {
  const v = Math.round(Number(val));
  onVolumeSliderInput(v);
  await apiFetch('/api/volume', {
    method: 'POST',
    body: JSON.stringify({ volume: v })
  });
  showSnackbar('服务器播放音量已设为 ' + v + '%');
}

function toggleVolumePopover(ev) {
  ev.stopPropagation();
  document.getElementById('volumePopover').classList.toggle('open');
}

document.addEventListener('click', (ev) => {
  const pop = document.getElementById('volumePopover');
  if (pop && pop.classList.contains('open') && !pop.contains(ev.target)) {
    pop.classList.remove('open');
  }
});

// ==================== 聊天交互与快捷操作 ====================
function autoGrowInput(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 110) + 'px';
}

function onChatInputKey(ev) {
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    sendChat();
  }
}

async function sendChat() {
  const input = document.getElementById('chatInput');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  input.style.height = 'auto';
  await apiFetch('/api/chat', {
    method: 'POST',
    body: JSON.stringify({ text, speak: true })
  });
}

async function captureAndAsk() {
  showSnackbar('正在调用服务器摄像头抓拍并提问...');
  await apiFetch('/api/capture-and-ask', {
    method: 'POST',
    body: JSON.stringify({ question: '这是什么，介绍一下' })
  });
}

async function toggleMic() {
  await apiFetch('/toggle-mic', { method: 'POST', body: '{}' });
}

async function toggleManualRecord() {
  const endpoint = appState.isManualRecording ? '/api/manual-record/stop' : '/api/manual-record/start';
  await apiFetch(endpoint, { method: 'POST', body: '{}' });
}

async function interruptSpeaking() {
  await apiFetch('/simulate', {
    method: 'POST',
    body: JSON.stringify({ text: '停止' })
  });
}

async function resetSession() {
  await apiFetch('/reset', { method: 'POST', body: '{}' });
  showSnackbar('已开启新对话');
}

// ==================== 左侧历史抽屉逻辑 (ChatHistoryDrawer) ====================
function openDrawer() {
  document.getElementById('drawerBackdrop').classList.add('open');
  document.getElementById('historyDrawer').classList.add('open');
  renderDrawerSessions();
}

function closeDrawer() {
  document.getElementById('drawerBackdrop').classList.remove('open');
  document.getElementById('historyDrawer').classList.remove('open');
}

function clearDrawerSearch() {
  document.getElementById('drawerSearchInput').value = '';
  renderDrawerSessions();
}

function getTimeGroupLabel(isoStr) {
  const d = new Date(isoStr);
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterdayStart = new Date(todayStart.getTime() - 86400000);
  const sevenDaysStart = new Date(todayStart.getTime() - 7 * 86400000);
  if (d >= todayStart) return '今天';
  if (d >= yesterdayStart) return '昨天';
  if (d >= sevenDaysStart) return '过去 7 天';
  return '更早';
}

function renderDrawerSessions() {
  const q = (document.getElementById('drawerSearchInput').value || '').trim().toLowerCase();
  document.getElementById('drawerSearchClearBtn').style.display = q ? 'inline-flex' : 'none';
  const all = appState.sessions || [];
  const filtered = q ? all.filter(s => (s.title || '').toLowerCase().includes(q)) : all;
  const listEl = document.getElementById('drawerSessionList');
  const footerEl = document.getElementById('drawerFooter');
  footerEl.style.display = all.length > 0 ? 'flex' : 'none';

  if (filtered.length === 0) {
    listEl.innerHTML = '<div style="text-align:center;padding:24px;font-size:13px;color:var(--fg-sub);">' +
      (all.length === 0 ? '暂无历史对话' : '未找到匹配的对话') + '</div>';
    return;
  }

  const groups = { '今天': [], '昨天': [], '过去 7 天': [], '更早': [] };
  for (const s of filtered) {
    groups[getTimeGroupLabel(s.updatedAt)].push(s);
  }

  let html = '';
  for (const g of ['今天', '昨天', '过去 7 天', '更早']) {
    if (groups[g].length === 0) continue;
    html += '<div class="drawer-group-title">' + g + '</div>';
    for (const s of groups[g]) {
      const sel = s.id === appState.currentSessionId ? ' selected' : '';
      html +=
        '<div class="session-tile' + sel + '" onclick="switchSession(\'' + s.id + '\')">' +
          '<svg class="ic-sm" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>' +
          '<span class="session-tile-title">' + escapeHtml(s.title) + '</span>' +
          '<span class="session-tile-actions" onclick="event.stopPropagation();">' +
            '<button class="icon-btn" style="width:28px;height:28px;" title="重命名" onclick="openRenameModal(\'' + s.id + '\', \'' + escapeHtml(s.title).replace(/'/g, "\\'") + '\')">' +
              '<svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a.996.996 0 0 0 0-1.41l-2.34-2.34a.996.996 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>' +
            '</button>' +
            '<button class="icon-btn" style="width:28px;height:28px;color:var(--danger);" title="删除" onclick="deleteSession(\'' + s.id + '\')">' +
              '<svg class="ic-sm" style="width:16px;height:16px;" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>' +
            '</button>' +
          '</span>' +
        '</div>';
    }
  }
  listEl.innerHTML = html;
}

async function switchSession(id) {
  closeDrawer();
  await apiFetch('/api/sessions/switch', {
    method: 'POST',
    body: JSON.stringify({ id })
  });
}

function openRenameModal(id, title) {
  renamingSessionId = id;
  document.getElementById('renameSessionInput').value = title;
  document.getElementById('renameModal').classList.add('open');
}

function closeRenameModal() {
  document.getElementById('renameModal').classList.remove('open');
}

async function confirmRenameSession() {
  const title = document.getElementById('renameSessionInput').value.trim();
  if (!title) return;
  closeRenameModal();
  await apiFetch('/api/sessions/rename', {
    method: 'POST',
    body: JSON.stringify({ id: renamingSessionId, title })
  });
}

async function deleteSession(id) {
  await apiFetch('/api/sessions/delete', {
    method: 'POST',
    body: JSON.stringify({ id })
  });
}

function openClearAllDialog() {
  document.getElementById('clearAllModal').classList.add('open');
}

function closeClearAllDialog() {
  document.getElementById('clearAllModal').classList.remove('open');
}

async function confirmClearAllHistory() {
  closeClearAllDialog();
  closeDrawer();
  await apiFetch('/api/sessions/clear', { method: 'POST', body: '{}' });
  showSnackbar('已清空全部历史对话');
}

function exportAllHistoryHtml() {
  const tokenParam = accessPassword ? ('?token=' + encodeURIComponent(accessPassword)) : '';
  window.open('/api/export-html' + tokenParam, '_blank');
}

// ==================== 设置页 (SettingsScreen) 逻辑 ====================

// 静音断句超时（0.1~10 秒）的展示格式化：整数秒不带小数，其余保留 1 位。
function fmtSilenceSecLabel(v) {
  const n = Number(v);
  if (!isFinite(n)) return '10 秒';
  return (Number.isInteger(n) ? String(n) : n.toFixed(1)) + ' 秒';
}

function getVal(id) {
  const el = document.getElementById(id);
  return el ? el.value.trim() : '';
}

function getBool(id) {
  const el = document.getElementById(id);
  return el ? !!el.checked : false;
}

function getInt(id, fallback = 0) {
  const el = document.getElementById(id);
  if (!el) return fallback;
  const n = parseInt(el.value, 10);
  return Number.isFinite(n) ? n : fallback;
}

async function openSettingsScreen() {
  document.getElementById('homeScreen').classList.remove('active');
  document.getElementById('settingsScreen').classList.add('active');
  await loadSettingsAndHardware();
}

async function closeSettingsScreen() {
  if (appState.isMicTesting) {
    await apiFetch('/api/mic-test', {
      method: 'POST',
      body: JSON.stringify({ enabled: false })
    });
  }
  document.getElementById('settingsScreen').classList.remove('active');
  document.getElementById('homeScreen').classList.add('active');
}

async function loadSettingsAndHardware() {
  const [sRes, hwRes] = await Promise.all([
    apiFetch('/api/settings'),
    apiFetch('/api/hardware-devices')
  ]);
  const sData = await sRes.json();
  hardwareDevices = await hwRes.json();
  currentSettings = sData.settings || {};
  populateSettingsForm(currentSettings);
  applySpeakerMeta(sData);
  populateHardwareSelects();
}

// 声纹面板的元信息（样本数与当前模型），来自 /api/settings 顶层字段
function applySpeakerMeta(meta) {
  const countEl = document.getElementById('lbl_speakerEnrolledCount');
  if (countEl && typeof meta.speakerEnrolledCount === 'number') {
    countEl.textContent = meta.speakerEnrolledCount;
  }
  const modelEl = document.getElementById('lbl_speakerModelName');
  if (modelEl && meta.speakerModelLabel) {
    modelEl.textContent = meta.speakerModelLabel;
  }
  const staleEl = document.getElementById('lbl_speakerStale');
  if (staleEl) {
    const stale = (typeof meta.speakerStoredCount === 'number' &&
            typeof meta.speakerEnrolledCount === 'number')
        ? Math.max(0, meta.speakerStoredCount - meta.speakerEnrolledCount)
        : 0;
    staleEl.style.display = stale > 0 ? 'block' : 'none';
    staleEl.textContent = stale > 0
        ? '检测到 ' + stale + ' 个旧模型声纹样本已失效（不参与比对），请点“清空声纹”后重新录制。'
        : '';
  }
}

async function loadHardwareDevices() {
  const hwRes = await apiFetch('/api/hardware-devices');
  hardwareDevices = await hwRes.json();
  populateHardwareSelects();
  showSnackbar('硬件外设列表已刷新');
}

function populateHardwareSelects() {
  // 录音输入源
  const inSel = document.getElementById('cfg_audioInputDeviceId');
  const curIn = currentSettings.audioInputDeviceId || '';
  let inHtml = '<option value="">自动（系统默认，推荐）</option>';
  for (const d of (hardwareDevices.inputDevices || [])) {
    inHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  inSel.innerHTML = inHtml;
  inSel.value = curIn;

  // 扬声器输出设备
  const outSel = document.getElementById('cfg_audioOutputDeviceId');
  const curOut = currentSettings.audioOutputDeviceId || '';
  let outHtml = '<option value="">自动（系统默认，推荐）</option>';
  for (const d of (hardwareDevices.outputDevices || [])) {
    outHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  outSel.innerHTML = outHtml;
  outSel.value = curOut;

  // 本地 V4L2 摄像头
  const camSel = document.getElementById('cfg_linuxCameraDevice');
  const curCam = currentSettings.linuxCameraDevice || '';
  let camHtml = '<option value="">自动选择主摄像头 (/dev/video0)</option>';
  for (const d of (hardwareDevices.cameraDevices || [])) {
    camHtml += '<option value="' + escapeHtml(d.id) + '">' + escapeHtml(d.label) + '</option>';
  }
  camSel.innerHTML = camHtml;
  camSel.value = curCam;
}

function populateSettingsForm(s) {
  const textIds = [
    'pipelineMode', 'asrEngine', 'geminiApiKey', 'geminiAsrModel', 'geminiLiveModel', 'geminiLiveVoice',
    'geminiLiveAdvancedMode', 'geminiLiveThinkingLevel',
    'startWord',
    'openAiBaseUrl', 'openAiApiKey', 'openAiModel', 'systemPrompt', 'locationAddress',
    'openCodeCommand', 'codeAgentProvider', 'hermesCommand',
    'ttsEngine', 'edgeVoice', 'cameraSendShortEdge', 'webAccessPassword'
  ];
  for (const id of textIds) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) el.value = String(s[id]);
  }
  onPipelineModeChanged();
  updateCodeAgentProviderUI();

  const boolIds = [
    'autoSubmitOnTimeout', 'disableThinking', 'enableWebSearch',
    'enableOpenCode',
    'enableTtsPlayback', 'enableBargeIn',
    'enablePromptTone', 'enableVisionIntent', 'autoStartMicOnLaunch',
    'enableSpeakerVerification', 'speakerVerifyWakeOnly',
    'enableTargetSpeakerExtraction', 'geminiLiveIncludeThoughts'
  ];
  for (const id of boolIds) {
    const el = document.getElementById('cfg_' + id);
    if (el) el.checked = !!s[id];
  }

  const intIds = ['openCodeTimeoutSeconds', 'openCodeProgressIntervalSeconds'];
  for (const id of intIds) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) el.value = s[id];
  }
  if (s.openCodeTimeoutSeconds !== undefined) {
    const el = document.getElementById('cfg_openCodeTimeoutSeconds');
    if (el) el.value = s.openCodeTimeoutSeconds;
  }
  try {
    loadCustomTools();
  } catch (_) {}
  const mode = s.startWordMode || (s.enableStartWordDetection === false ? 'disabled' : 'auto');
  const modeEl = document.getElementById('cfg_startWordMode');
  if (modeEl) {
    modeEl.value = mode;
    onStartWordModeChange();
  }
  const timeoutVal = s.continuousModeTimeoutMinutes || 10;
  const timeoutEl = document.getElementById('cfg_continuousModeTimeoutMinutes');
  if (timeoutEl) timeoutEl.value = timeoutVal;
  const timeoutLbl = document.getElementById('lbl_continuousModeTimeoutMinutes');
  if (timeoutLbl) timeoutLbl.textContent = timeoutVal;
  if (s.speakerVerifyWakeOnly === undefined) {
    const wEl = document.getElementById('cfg_speakerVerifyWakeOnly');
    if (wEl) wEl.checked = true;
  }
  const countEl = document.getElementById('lbl_speakerEnrolledCount');
  if (countEl) countEl.textContent = (s.ownerSpeakerEmbeddings || []).length;

  const sliders = [
    ['vadThreshold', v => Number(v).toFixed(2)],
    ['vadMinSilenceSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['vadMinSpeechSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['vadMaxSpeechSeconds', v => Number(v).toFixed(0) + ' 秒'],
    ['preRollMs', v => Number(v).toFixed(0) + ' 毫秒'],
    ['postRollMs', v => Number(v).toFixed(0) + ' 毫秒'],
    ['speakerSimilarityThreshold', v => Math.round(v * 100) + '%'],
    ['speakerMinSpeechSeconds', v => Number(v).toFixed(2) + ' 秒'],
    ['speakerEnergyThreshold', v => Number(v).toFixed(5)],
    ['tseAttenuationDb', v => Math.round(v) + ' dB'],
    ['silenceTimeoutSeconds', v => fmtSilenceSecLabel(v)],
    ['playbackVolume', v => Math.round(v) + '%'],
    ['ttsSpeed', v => Number(v).toFixed(1) + 'x'],
    ['cameraKeepAliveMinutes', v => v + ' 分钟']
  ];
  for (const [id, fmt] of sliders) {
    const el = document.getElementById('cfg_' + id);
    if (el && s[id] !== undefined) {
      el.value = s[id];
      updateSliderLabel(id, fmt(s[id]));
    }
  }

  availableModels = Array.isArray(s.cachedAvailableModels) ? [...s.cachedAvailableModels] : [];
  const curModel = (s.openAiModel || '').trim();
  if (curModel && !availableModels.includes(curModel)) availableModels.unshift(curModel);
  if (availableModels.length === 0) availableModels = ['CLI.gemini-3.8-flash-high', 'WB.deepseek-v4.1-flash', 'gpt-4o-mini'];
  renderModelSelect();
}

function onPipelineModeChanged() {
  const modeEl = document.getElementById('cfg_pipelineMode');
  const isLive = modeEl && modeEl.value === 'gemini_live';
  const asrGroup = document.getElementById('cascadeAsrEngineGroup');
  if (asrGroup) asrGroup.style.display = isLive ? 'none' : 'block';
  const liveFields = document.getElementById('geminiLiveFieldsGroup');
  if (liveFields) liveFields.style.display = isLive ? 'block' : 'none';
  const previewVoiceBtn = document.getElementById('previewGeminiVoiceBtn');
  if (previewVoiceBtn) previewVoiceBtn.style.display = isLive ? '' : 'none';
  const asrModelGroup = document.getElementById('geminiAsrModelGroup');
  if (asrModelGroup) asrModelGroup.style.display = isLive ? 'none' : 'block';
  const expansion = document.getElementById('geminiCloudExpansion');
  if (expansion && isLive) expansion.open = true;
  const openAiGroup = document.getElementById('cascadeOpenAiFieldsGroup');
  if (openAiGroup) openAiGroup.style.display = isLive ? 'none' : 'block';
  const llmHeader = document.getElementById('llmSectionHeaderTitle');
  if (llmHeader) {
    llmHeader.textContent = isLive ? '对话工具与系统人设（Gemini Live 生效）' : '大语言模型（OpenAI 兼容）';
  }
}

function updateCodeAgentProviderUI() {
  const provider = getVal('cfg_codeAgentProvider') || 'opencode';
  const openCodeGroup = document.getElementById('openCodeCmdGroup');
  const hermesGroup = document.getElementById('hermesCmdGroup');
  if (openCodeGroup) openCodeGroup.style.display = provider === 'hermes' ? 'none' : '';
  if (hermesGroup) hermesGroup.style.display = provider === 'hermes' ? '' : 'none';
}

function renderModelSelect() {
  const sel = document.getElementById('cfg_openAiModelSelect');
  const inp = document.getElementById('cfg_openAiModel');
  const cur = inp.value.trim();
  if (cur && !availableModels.includes(cur)) availableModels.unshift(cur);
  sel.innerHTML = availableModels.map(m => '<option value="' + escapeHtml(m) + '">' + escapeHtml(m) + '</option>').join('');
  sel.value = cur || availableModels[0];
}

function onModelSelectChanged(val) {
  document.getElementById('cfg_openAiModel').value = val;
  scheduleAutoSave(true);
}

function toggleManualModelInput() {
  isManualModelInput = !isManualModelInput;
  document.getElementById('cfg_openAiModelSelect').style.display = isManualModelInput ? 'none' : 'block';
  document.getElementById('cfg_openAiModel').style.display = isManualModelInput ? 'block' : 'none';
  document.getElementById('modelFieldLabel').textContent = isManualModelInput ? '模型名称（手动输入）' : '模型名称（下拉选择）';
  if (!isManualModelInput) renderModelSelect();
}

async function fetchAvailableModels() {
  const baseUrl = document.getElementById('cfg_openAiBaseUrl').value.trim();
  const apiKey = document.getElementById('cfg_openAiApiKey').value.trim();
  const res = await apiFetch('/api/fetch-models', {
    method: 'POST',
    body: JSON.stringify({ baseUrl, apiKey })
  });
  const data = await res.json();
  if (Array.isArray(data.models) && data.models.length > 0) {
    availableModels = data.models;
    renderModelSelect();
    showSnackbar('成功获取到 ' + data.models.length + ' 个可用模型');
  } else {
    showSnackbar('获取模型列表失败: ' + (data.error || '无可用模型'));
  }
}

function updateSliderLabel(id, text) {
  const lbl = document.getElementById('lbl_' + id);
  if (lbl) lbl.textContent = text;
}

async function onAudioInputSelectChanged() {
  const sel = document.getElementById('cfg_audioInputDeviceId');
  const id = sel.value;
  const label = id ? (sel.options[sel.selectedIndex]?.text || '') : '';
  await apiFetch('/audio-device', {
    method: 'POST',
    body: JSON.stringify({ id, label })
  });
  showSnackbar('录音输入源已切换');
}

function scheduleAutoSave(immediate = false) {
  clearTimeout(autoSaveTimer);
  document.getElementById('autoSaveBadge').textContent = '保存中...';
  if (immediate) {
    saveAllSettings();
  } else {
    autoSaveTimer = setTimeout(saveAllSettings, 450);
  }
}

async function saveAllSettings() {
  const outSel = document.getElementById('cfg_audioOutputDeviceId');
  const outId = outSel.value;
  const outLabel = outId ? (outSel.options[outSel.selectedIndex]?.text || '') : '';

  const payload = {
    pipelineMode: document.getElementById('cfg_pipelineMode').value,
    asrEngine: document.getElementById('cfg_asrEngine').value,
    geminiApiKey: document.getElementById('cfg_geminiApiKey').value.trim(),
    geminiAsrModel: document.getElementById('cfg_geminiAsrModel').value.trim(),
    geminiLiveModel: document.getElementById('cfg_geminiLiveModel').value.trim(),
    geminiLiveVoice: document.getElementById('cfg_geminiLiveVoice').value,
    geminiLiveAdvancedMode: document.getElementById('cfg_geminiLiveAdvancedMode').value,
    geminiLiveThinkingLevel: document.getElementById('cfg_geminiLiveThinkingLevel').value,
    geminiLiveIncludeThoughts: document.getElementById('cfg_geminiLiveIncludeThoughts').checked,
    autoSubmitOnTimeout: document.getElementById('cfg_autoSubmitOnTimeout').checked,
    vadThreshold: Number(document.getElementById('cfg_vadThreshold').value),
    vadMinSilenceSeconds: Number(document.getElementById('cfg_vadMinSilenceSeconds').value),
    vadMinSpeechSeconds: Number(document.getElementById('cfg_vadMinSpeechSeconds').value),
    vadMaxSpeechSeconds: Number(document.getElementById('cfg_vadMaxSpeechSeconds').value),
    preRollMs: Math.round(Number(document.getElementById('cfg_preRollMs').value)),
    postRollMs: Math.round(Number(document.getElementById('cfg_postRollMs').value)),
    startWord: document.getElementById('cfg_startWord').value.trim(),
    startWordMode: document.getElementById('cfg_startWordMode') ? document.getElementById('cfg_startWordMode').value : 'auto',
    continuousModeTimeoutMinutes: document.getElementById('cfg_continuousModeTimeoutMinutes') ? Number(document.getElementById('cfg_continuousModeTimeoutMinutes').value) : 10,
    enableStartWordDetection: document.getElementById('cfg_startWordMode') ? document.getElementById('cfg_startWordMode').value !== 'disabled' : true,
    silenceTimeoutSeconds: Number(Number(document.getElementById('cfg_silenceTimeoutSeconds').value).toFixed(1)),
    openAiBaseUrl: document.getElementById('cfg_openAiBaseUrl').value.trim(),
    openAiApiKey: document.getElementById('cfg_openAiApiKey').value.trim(),
    openAiModel: document.getElementById('cfg_openAiModel').value.trim(),
    disableThinking: document.getElementById('cfg_disableThinking').checked,
    enableWebSearch: document.getElementById('cfg_enableWebSearch').checked,
    enableOpenCode: getBool('cfg_enableOpenCode'),
    codeAgentProvider: getVal('cfg_codeAgentProvider') || 'opencode',
    openCodeCommand: getVal('cfg_openCodeCommand'),
    hermesCommand: getVal('cfg_hermesCommand'),
    openCodeTimeoutSeconds: getInt('cfg_openCodeTimeoutSeconds', 0),
    openCodeProgressIntervalSeconds: getInt('cfg_openCodeProgressIntervalSeconds', 15),
    systemPrompt: document.getElementById('cfg_systemPrompt').value.trim(),
    locationAddress: document.getElementById('cfg_locationAddress').value.trim(),
    enableTtsPlayback: document.getElementById('cfg_enableTtsPlayback').checked,
    enableBargeIn: document.getElementById('cfg_enableBargeIn').checked,
    enablePromptTone: document.getElementById('cfg_enablePromptTone').checked,
    playbackVolume: Math.round(Number(document.getElementById('cfg_playbackVolume').value)),
    ttsSpeed: Number(document.getElementById('cfg_ttsSpeed').value),
    audioOutputDeviceId: outId,
    audioOutputDeviceLabel: outLabel,
    ttsEngine: document.getElementById('cfg_ttsEngine').value,
    edgeVoice: document.getElementById('cfg_edgeVoice').value,
    enableVisionIntent: document.getElementById('cfg_enableVisionIntent').checked,
    linuxCameraDevice: document.getElementById('cfg_linuxCameraDevice').value,
    cameraSendShortEdge: Math.round(Number(document.getElementById('cfg_cameraSendShortEdge').value)),
    cameraKeepAliveMinutes: Math.round(Number(document.getElementById('cfg_cameraKeepAliveMinutes').value)),
    enableSpeakerVerification: document.getElementById('cfg_enableSpeakerVerification').checked,
    speakerVerifyWakeOnly: document.getElementById('cfg_speakerVerifyWakeOnly').checked,
    speakerSimilarityThreshold: Number(document.getElementById('cfg_speakerSimilarityThreshold').value),
    speakerMinSpeechSeconds: Number(document.getElementById('cfg_speakerMinSpeechSeconds').value),
    speakerEnergyThreshold: Number(document.getElementById('cfg_speakerEnergyThreshold').value),
    enableTargetSpeakerExtraction: document.getElementById('cfg_enableTargetSpeakerExtraction').checked,
    tseAttenuationDb: Number(document.getElementById('cfg_tseAttenuationDb').value),
    autoStartMicOnLaunch: document.getElementById('cfg_autoStartMicOnLaunch').checked,
    webAccessPassword: document.getElementById('cfg_webAccessPassword').value.trim()
  };

  const res = await apiFetch('/api/settings', {
    method: 'POST',
    body: JSON.stringify(payload)
  });
  const data = await res.json();
  currentSettings = data.settings || payload;
  if (payload.webAccessPassword) {
    accessPassword = payload.webAccessPassword;
    localStorage.setItem('sa_web_password', accessPassword);
  }
  document.getElementById('autoSaveBadge').textContent = '已自动保存';
}

async function testGeminiConnection() {
  const btn = document.getElementById('testGeminiBtn');
  const out = document.getElementById('geminiTestResult');
  const isLive = document.getElementById('cfg_pipelineMode').value === 'gemini_live';
  const modelVal = isLive
    ? (document.getElementById('cfg_geminiLiveModel').value.trim() || 'gemini-3.8-live')
    : document.getElementById('cfg_geminiAsrModel').value.trim();
  btn.disabled = true;
  out.textContent = '正在连接 Gemini...';
  try {
    const res = await apiFetch('/api/test-gemini', {
      method: 'POST',
      body: JSON.stringify({
        apiKey: document.getElementById('cfg_geminiApiKey').value.trim(),
        model: modelVal
      })
    });
    const data = await res.json();
    out.textContent = data.result || '';
    out.style.color = (data.result || '').startsWith('连接成功') ? 'var(--accent)' : 'var(--danger)';
  } finally {
    btn.disabled = false;
  }
}

async function previewGeminiLiveVoice() {
  const btn = document.getElementById('previewGeminiVoiceBtn');
  const voice = document.getElementById('cfg_geminiLiveVoice')?.value || 'Aoede';
  if (btn) btn.disabled = true;
  showSnackbar('正在通过服务器扬声器试听 Gemini Live 音色 (' + voice + ')...');
  try {
    if (typeof saveSettings === 'function') await saveSettings(true);
    await apiFetch('/api/preview-voice', {
      method: 'POST',
      body: JSON.stringify({
        voice: voice,
        text: '你好，我是晓漫，这是 Gemini Live ' + voice + ' 原生音色的试听效果。'
      })
    });
  } catch (e) {
    showSnackbar('试听请求失败: ' + e);
  } finally {
    if (btn) {
      setTimeout(() => {
        btn.disabled = false;
      }, 1000);
    }
  }
}

let isEnrollingSpeaker = false;

// 声纹测试得分面板：大号百分比 + 进度条 + 明细
function hideSpeakerScore() {
  const panel = document.getElementById('speakerScorePanel');
  if (panel) panel.style.display = 'none';
}

function renderSpeakerScore(data) {
  const panel = document.getElementById('speakerScorePanel');
  if (!panel) return;
  const sim = typeof data.similarity === 'number' ? data.similarity : null;
  if (data.error || sim === null) {
    hideSpeakerScore();
    return;
  }
  const color = data.passed ? 'var(--accent)' : 'var(--danger)';
  const percent = document.getElementById('speakerScorePercent');
  const verdict = document.getElementById('speakerScoreVerdict');
  const fill = document.getElementById('speakerScoreFill');
  const meta = document.getElementById('speakerScoreMeta');
  const samples = document.getElementById('speakerScoreSamples');
  if (percent) {
    percent.textContent = (sim * 100).toFixed(1) + '%';
    percent.style.color = color;
  }
  if (verdict) {
    verdict.textContent = data.passed ? '✅ 判定为主人' : '❌ 非主人声纹';
    verdict.style.color = color;
  }
  if (fill) {
    fill.style.width = Math.max(0, Math.min(100, sim * 100)).toFixed(1) + '%';
    fill.style.background = color;
  }
  const thr = typeof data.threshold === 'number'
      ? (data.threshold * 100).toFixed(0) + '%' : '-';
  const speech = typeof data.speechSeconds === 'number'
      ? data.speechSeconds.toFixed(2) + 's' : '-';
  const centroid = typeof data.centroidSimilarity === 'number'
      ? (data.centroidSimilarity * 100).toFixed(1) + '%' : '-';
  const best = typeof data.maxSampleSimilarity === 'number'
      ? (data.maxSampleSimilarity * 100).toFixed(1) + '%' : '-';
  const mean = typeof data.meanSampleSimilarity === 'number'
      ? (data.meanSampleSimilarity * 100).toFixed(1) + '%' : '-';
  if (meta) {
    meta.textContent = '判定阈值 ' + thr + ' · 有效语音 ' + speech +
        ' · 质心 ' + centroid + ' · 单样本最高 ' + best + ' · 均值 ' + mean +
        ' · 耗时 ' + (data.durationMs || 0) + 'ms';
  }
  const list = Array.isArray(data.samplePercents) ? data.samplePercents : [];
  if (samples) {
    samples.textContent = list.length
        ? '与各录音样本相似度: ' + list.map(p => Number(p).toFixed(1) + '%').join('  |  ')
        : '';
  }
  panel.style.display = 'block';
}

async function enrollSpeakerSample() {
  if (isEnrollingSpeaker) return;
  isEnrollingSpeaker = true;
  const btn = document.getElementById('btnEnrollSpeaker');
  const out = document.getElementById('speakerTestResult');
  btn.disabled = true;
  hideSpeakerScore();

  const totalSeconds = 3.5;
  let remaining = 3;
  btn.textContent = '🎙️ 正在录制 (3s)...';
  if (out) {
    out.style.color = 'var(--accent)';
    out.textContent = '🎙️ 正在录音中，请对着麦克风清晰朗读 3 秒（例如：“小曼小曼，今天天气怎么样”）...';
  }
  showSnackbar('🎙️ 录音已开始，请对着麦克风清晰朗读 3 秒...', 3500);

  const timer = setInterval(() => {
    remaining--;
    if (remaining > 0) {
      btn.textContent = '🎙️ 正在录制 (' + remaining + 's)...';
    } else {
      btn.textContent = '⚙️ 正在分析声纹特征...';
      clearInterval(timer);
    }
  }, 1000);

  try {
    const res = await apiFetch('/api/speaker/enroll', {
      method: 'POST',
      body: JSON.stringify({ record: true, seconds: totalSeconds })
    });
    clearInterval(timer);
    btn.textContent = '⚙️ 正在保存...';
    const data = await res.json();
    if (data.accepted) {
      document.getElementById('lbl_speakerEnrolledCount').textContent = data.enrolledCount;
      showSnackbar('✅ 成功录入主人声纹样本！共有 ' + data.enrolledCount + ' 个样本');
      if (out) {
        out.style.color = 'var(--accent)';
        out.textContent = '✅ 样本录入成功！当前共有 ' + data.enrolledCount + ' / 5 个声纹样本';
      }
    } else {
      showSnackbar('❌ ' + (data.error || '录入失败'));
      if (out) {
        out.style.color = 'var(--danger)';
        out.textContent = '❌ ' + (data.error || '录入失败');
      }
    }
  } catch (e) {
    clearInterval(timer);
    showSnackbar('❌ 录入异常: ' + e);
    if (out) {
      out.style.color = 'var(--danger)';
      out.textContent = '录入异常: ' + e;
    }
  } finally {
    clearInterval(timer);
    isEnrollingSpeaker = false;
    btn.disabled = false;
    btn.textContent = '录入当前说话声音为样本';
  }
}

let isTestingSpeaker = false;

async function testSpeakerSample() {
  if (isTestingSpeaker) return;
  isTestingSpeaker = true;
  const btn = document.getElementById('btnTestSpeaker');
  const out = document.getElementById('speakerTestResult');
  btn.disabled = true;
  hideSpeakerScore();

  const totalSeconds = 3.0;
  let remaining = 3;
  btn.textContent = '🎙️ 正在录制 (3s)...';
  if (out) {
    out.style.color = 'var(--accent)';
    out.textContent = '🎙️ 正在录音中，请只说一句话，或只播放电视声（不要同时有人说话）...';
  }
  showSnackbar('🎙️ 录音测试已开始，请说一句话或播放电视声...', 3000);

  const timer = setInterval(() => {
    remaining--;
    if (remaining > 0) {
      btn.textContent = '🎙️ 正在录制 (' + remaining + 's)...';
    } else {
      btn.textContent = '⚙️ 正在比对特征...';
      clearInterval(timer);
    }
  }, 1000);

  try {
    const res = await apiFetch('/api/speaker/test', {
      method: 'POST',
      body: JSON.stringify({ record: true, seconds: totalSeconds })
    });
    clearInterval(timer);
    const data = await res.json();
    if (out) {
      out.textContent = data.text || data.error || '未知比对结果';
      out.style.color = data.passed ? 'var(--accent)' : 'var(--danger)';
    }
    renderSpeakerScore(data);
    applySpeakerMeta(data);
    if (data.error) {
      showSnackbar('❌ ' + data.error);
    } else if (data.text) {
      showSnackbar((data.passed ? '✅ ' : '⚠️ ') + data.text);
    }
  } catch (e) {
    clearInterval(timer);
    hideSpeakerScore();
    if (out) {
      out.textContent = '比对异常: ' + e;
      out.style.color = 'var(--danger)';
    }
    showSnackbar('❌ 比对异常: ' + e);
  } finally {
    clearInterval(timer);
    isTestingSpeaker = false;
    btn.disabled = false;
    btn.textContent = '测试最新声音相似度';
  }
}

async function clearSpeakerProfile() {
  if (!confirm('确定要清空所有已保存的主人声纹样本吗？')) return;
  try {
    await apiFetch('/api/speaker/clear', { method: 'POST' });
    document.getElementById('lbl_speakerEnrolledCount').textContent = '0';
    document.getElementById('speakerTestResult').textContent = '';
    hideSpeakerScore();
    showSnackbar('已清空主人声纹样本');
  } catch (e) {
    showSnackbar('清空异常: ' + e);
  }
}

async function previewServerVoice() {
  const voice = document.getElementById('cfg_edgeVoice')?.value || 'zh-CN-XiaoxiaoNeural';
  showSnackbar('正在通过服务器扬声器试听音色...');
  await apiFetch('/api/preview-voice', {
    method: 'POST',
    body: JSON.stringify({
      voice,
      text: '你好，我是晓漫，这是我的全新神经网络发音效果。'
    })
  });
}

async function testCameraCapture() {
  const dev = document.getElementById('cfg_linuxCameraDevice').value;
  const box = document.getElementById('cameraTestPreview');
  box.innerHTML = '<span style="font-size:12px;color:var(--fg-sub);">正在从服务器摄像头抓拍...</span>';
  const res = await apiFetch('/api/test-camera', {
    method: 'POST',
    body: JSON.stringify({ device: dev })
  });
  const data = await res.json();
  if (data.base64) {
    box.innerHTML =
      '<div style="font-size:12px;color:var(--accent);margin-bottom:4px;">✅ 抓拍成功 (' + data.byteLength + ' 字节)</div>' +
      '<img src="data:image/jpeg;base64,' + data.base64 + '" style="max-width:240px;border-radius:12px;cursor:pointer;" onclick="openImageViewer(this.src)">';
  } else {
    box.innerHTML = '<span style="font-size:12px;color:var(--danger);">❌ 抓拍失败: ' + escapeHtml(data.error || '') + '</span>';
  }
}

async function runDiagnosticSelfTest() {
  const btn = document.getElementById('selfTestBtn');
  const logBox = document.getElementById('selfTestLogBox');
  btn.disabled = true;
  btn.textContent = '正在执行自检...';
  logBox.style.display = 'block';
  logBox.textContent = '正在启动全链路 6 步运行态诊断...';
  try {
    const res = await apiFetch('/run-self-test', { method: 'POST', body: '{}' });
    const data = await res.json();
    if (Array.isArray(data.logs)) {
      logBox.textContent = data.logs.join('\n');
      logBox.scrollTop = logBox.scrollHeight;
    }
  } finally {
    btn.disabled = false;
    btn.textContent = '开始全链路诊断';
  }
}

function openImageViewer(src) {
  document.getElementById('imageViewerImg').src = src;
  document.getElementById('imageViewerModal').classList.add('open');
}

function closeImageViewer() {
  document.getElementById('imageViewerModal').classList.remove('open');
}

async function loadCustomTools() {
  const container = document.getElementById('customToolsList');
  if (!container) return;
  try {
    const res = await apiFetch('/api/custom-tools');
    if (!res.ok) {
      container.innerHTML = '<div style="color:var(--danger);font-size:12px;">加载工具列表失败 (' + res.status + ')</div>';
      return;
    }
    const data = await res.json();
    const tools = Array.isArray(data.tools) ? data.tools : [];
    if (tools.length === 0) {
      container.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:4px 0;">暂无持久化工具。可在对话中让助手写一个持久化工具自动创建。</div>';
      return;
    }
    let html = '';
    for (const tool of tools) {
      const name = escapeHtml(tool.name || '');
      const summary = escapeHtml(tool.summary || '');
      const hint = escapeHtml(tool.parametersHint || '');
      const cmd = escapeHtml(tool.command || '');
      html += '<div style="background:var(--surface-container);border-radius:6px;padding:8px 10px;display:flex;justify-content:space-between;align-items:flex-start;gap:8px;border:1px solid var(--outline-variant);">'
        + '<div style="flex:1;min-width:0;">'
        + '<div style="font-weight:600;font-family:monospace;font-size:13px;color:var(--primary);">' + name + '</div>'
        + '<div style="font-size:12px;color:var(--on-surface);margin-top:2px;">' + summary + '</div>'
        + (hint ? '<div style="font-size:11px;color:var(--text-muted);margin-top:2px;">参数: ' + hint + '</div>' : '')
        + (cmd ? '<div style="font-size:11px;color:var(--text-muted);font-family:monospace;margin-top:2px;">命令: ' + cmd + '</div>' : '')
        + '</div>'
        + '<button class="icon-btn" style="width:28px;height:28px;color:var(--danger);flex-shrink:0;" title="删除工具" onclick="deleteCustomTool(\'' + name + '\')">'
        + '<svg class="ic-sm" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>'
        + '</button>'
        + '</div>';
    }
    container.innerHTML = html;
  } catch (err) {
    container.innerHTML = '<div style="color:var(--danger);font-size:12px;">加载失败: ' + escapeHtml(String(err)) + '</div>';
  }
}

async function deleteCustomTool(name) {
  if (!name) return;
  if (!confirm('确定要删除持久化工具 "' + name + '" 吗？此操作不可撤销。')) return;
  try {
    const res = await apiFetch('/api/custom-tools/delete', {
      method: 'POST',
      body: JSON.stringify({ name: name })
    });
    const data = await res.json();
    if (data.deleted) {
      showSnackbar('已删除工具: ' + name);
    } else {
      showSnackbar('删除工具失败: ' + (data.error || '未知错误'));
    }
    await loadCustomTools();
  } catch (err) {
    showSnackbar('删除工具请求失败: ' + err);
  }
}

async function initApp() {
  try {
    const res = await apiFetch('/api/state');
    const data = await res.json();
    applyState(data);
    connectSse();
  } catch (_) {}
}

// 全局滚轮代理（对齐 Gemini Web：鼠标在窗口任意位置如顶栏、底栏、左右留白均可直接滚动当前视图）
window.addEventListener('wheel', (ev) => {
  if (ev.target.closest('.history-drawer, .modal-backdrop.open, .popover-card.open')) return;
  const innerScroll = ev.target.closest('textarea, .mono-log, .mic-test-history');
  if (innerScroll && innerScroll.scrollHeight > innerScroll.clientHeight) return;

  const activeScroll = document.getElementById('settingsScreen').classList.contains('active')
    ? document.getElementById('settingsScroll')
    : document.getElementById('chatList');
  if (!activeScroll) return;
  if (activeScroll.contains(ev.target)) return;
  activeScroll.scrollTop += ev.deltaY;
}, { passive: true });

initApp();
</script>
</body>
</html>''';
