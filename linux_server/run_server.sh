#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 补充用户态常用 CLI 工具路径 (如 opencode, hermes, cargo 等)，防止以 systemd 运行缺少 PATH
if [ -n "${HOME:-}" ]; then
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.opencode/bin:$HOME/.cargo/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
fi

export LD_LIBRARY_PATH="$APP_ROOT/lib:$SCRIPT_DIR/lib:${LD_LIBRARY_PATH:-}"
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  UID_NUM="$(id -u)"
  if [ -d "/run/user/$UID_NUM" ]; then
    export XDG_RUNTIME_DIR="/run/user/$UID_NUM"
  fi
fi

# 确保 WirePlumber 禁用蓝牙节点的空闲挂起 (仅在未配置时补充，严禁覆盖现有配置)
if [ -f "$SCRIPT_DIR/52-disable-suspend.lua" ] && [ ! -f "$HOME/.config/wireplumber/bluetooth.lua.d/52-disable-suspend.lua" ]; then
  mkdir -p "$HOME/.config/wireplumber/bluetooth.lua.d" 2>/dev/null || true
  cp -n "$SCRIPT_DIR/52-disable-suspend.lua" "$HOME/.config/wireplumber/bluetooth.lua.d/" 2>/dev/null || true
fi

cd "$APP_ROOT"

if [ -x "$APP_ROOT/side_assistant_server" ]; then
  exec "$APP_ROOT/side_assistant_server" "$@"
elif [ -f "$APP_ROOT/linux_server.dill" ] && [ -x "$HOME/.local/share/side_assistant/dart-sdk/bin/dart" ]; then
  exec "$HOME/.local/share/side_assistant/dart-sdk/bin/dart" run "$APP_ROOT/linux_server.dill" "$@"
else
  exec dart run bin/linux_server.dart "$@"
fi
