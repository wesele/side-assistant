#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
DATA_DIR="$TARGET_HOME/.local/share/side_assistant"
VENV_DIR="$DATA_DIR/venv"
PORT="${SIDE_ASSISTANT_PORT:-19823}"

echo "============================================================"
echo "  SideAssistant Linux Server 一键安装与服务配置"
echo "  应用目录: $APP_ROOT"
echo "  运行用户: $TARGET_USER ($TARGET_HOME)"
echo "  数据目录: $DATA_DIR"
echo "  监听端口: $PORT"
echo "============================================================"

echo "[1/5] 检查并安装 Ubuntu/Debian 音视频与语音依赖..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  alsa-utils \
  pulseaudio-utils \
  ffmpeg \
  v4l-utils \
  espeak-ng \
  python3 \
  python3-venv \
  python3-pip \
  curl \
  unzip

echo "[2/5] 配置用户硬件权限 (audio, video 用户组)..."
sudo usermod -aG audio,video "$TARGET_USER" || true

echo "[3/5] 配置 Edge-TTS Python 虚拟环境..."
mkdir -p "$DATA_DIR"
if [ ! -x "$VENV_DIR/bin/python" ]; then
  python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install edge-tts -q
chown -R "$TARGET_USER:$TARGET_USER" "$DATA_DIR"

echo "[4/5] 检查原生可执行程序与动态库..."
chmod +x "$SCRIPT_DIR/run_server.sh"
if [ ! -x "$APP_ROOT/side_assistant_server" ] && [ -f "$APP_ROOT/linux_server.dill" ]; then
  DART_BIN="$(command -v dart || true)"
  if [ -z "$DART_BIN" ]; then
    DART_SDK_DIR="$DATA_DIR/dart-sdk"
    if [ ! -x "$DART_SDK_DIR/bin/dart" ]; then
      echo "正在下载 Dart SDK 3.5.3 (linux-x64) 以编译原生可执行文件..."
      curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/3.5.3/sdk/dartsdk-linux-x64-release.zip" -o /tmp/dartsdk.zip
      unzip -q -o /tmp/dartsdk.zip -d "$DATA_DIR"
      rm -f /tmp/dartsdk.zip
    fi
    DART_BIN="$DART_SDK_DIR/bin/dart"
  fi
  echo "正在将 linux_server.dill 编译为 Linux x86_64 原生二进制文件..."
  "$DART_BIN" compile exe "$APP_ROOT/linux_server.dill" -o "$APP_ROOT/side_assistant_server"
  chmod +x "$APP_ROOT/side_assistant_server"
fi

echo "[5/5] 注册并启动 systemd 服务 (side-assistant.service)..."
TARGET_UID="$(id -u "$TARGET_USER")"
SERVICE_FILE="/etc/systemd/system/side-assistant.service"

# 已存在的 systemd 单元可能被用户手动改过（环境变量、端口等），默认保留不覆盖。
# 如需用默认模板重置，请设置 FORCE_REWRITE_SERVICE=1 后再运行本脚本。
if [ -f "$SERVICE_FILE" ] && [ "${FORCE_REWRITE_SERVICE:-0}" != "1" ]; then
  echo "检测到已有 $SERVICE_FILE，保留现有配置，不覆盖。"
else
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=SideAssistant Linux Voice & Vision Server
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=$APP_ROOT
SupplementaryGroups=audio video
Environment="HOME=$TARGET_HOME"
Environment="XDG_RUNTIME_DIR=/run/user/$TARGET_UID"
Environment="SIDE_ASSISTANT_DATA_DIR=$DATA_DIR"
Environment="SIDE_ASSISTANT_PORT=$PORT"
Environment="SIDE_ASSISTANT_PYTHON=$VENV_DIR/bin/python"
Environment="LD_LIBRARY_PATH=$APP_ROOT/lib:$SCRIPT_DIR/lib:/usr/local/lib"
ExecStart=$SCRIPT_DIR/run_server.sh --port=$PORT --data-dir=$DATA_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable side-assistant.service
sudo systemctl restart side-assistant.service

echo "============================================================"
echo "  ✅ 安装与启动完成！"
echo "  服务状态: sudo systemctl status side-assistant.service"
echo "  实时日志: sudo journalctl -u side-assistant.service -f"
echo "  Web 访问: http://$(hostname -I | awk '{print $1}'):$PORT"
echo "============================================================"
