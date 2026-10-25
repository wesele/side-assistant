#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export LD_LIBRARY_PATH="$APP_ROOT/lib:$SCRIPT_DIR/lib:${LD_LIBRARY_PATH:-}"
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  UID_NUM="$(id -u)"
  if [ -d "/run/user/$UID_NUM" ]; then
    export XDG_RUNTIME_DIR="/run/user/$UID_NUM"
  fi
fi

cd "$APP_ROOT"

if [ -x "$APP_ROOT/side_assistant_server" ]; then
  exec "$APP_ROOT/side_assistant_server" "$@"
elif [ -f "$APP_ROOT/linux_server.dill" ] && [ -x "$HOME/.local/share/side_assistant/dart-sdk/bin/dart" ]; then
  exec "$HOME/.local/share/side_assistant/dart-sdk/bin/dart" run "$APP_ROOT/linux_server.dill" "$@"
else
  exec dart run bin/linux_server.dart "$@"
fi
