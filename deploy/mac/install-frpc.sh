#!/bin/bash
# mac-display-remote 客户端:安装 frp 客户端(frpc)并注册 LaunchAgent
#
# 用法(在 Mac 本项目目录下):
#   ./deploy/mac/install-frpc.sh --server <云服务器公网IP> --token <隧道Token>
#
# 可选参数:
#   --frp-port      frp 控制端口,与云端一致,默认 47000
#   --remote-port   云端对外端口,与云端一致,默认 18977
#   --local-port    本机 server.py 端口,默认读 config.json,兜底 8977
#   --uninstall     移除 frpc 的 LaunchAgent 与配置
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="com.gaomeng.mac-display-remote-frpc"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/frpc"
CONF_DIR="$HOME/.config/frp"
CONF="$CONF_DIR/frpc.toml"
LOG="$REPO_DIR/logs/frpc.log"
MARK="# mac-display-remote frpc"

SERVER=""
TOKEN=""
FRP_PORT=47000
REMOTE_PORT=18977
LOCAL_PORT=""
FRP_VERSION=""

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
    cat <<'EOF'
用法(在 Mac 本项目目录下):
  ./deploy/mac/install-frpc.sh --server <云服务器公网IP> --token <隧道Token>

可选参数:
  --frp-port      frp 控制端口,与云端一致,默认 47000
  --remote-port   云端对外端口,与云端一致,默认 18977
  --local-port    本机 server.py 端口,默认读 config.json,兜底 8977
  --uninstall     移除 frpc 的 LaunchAgent 与配置
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --server)      SERVER="${2:-}"; shift 2 ;;
        --token)       TOKEN="${2:-}"; shift 2 ;;
        --frp-port)    FRP_PORT="${2:-}"; shift 2 ;;
        --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
        --local-port)  LOCAL_PORT="${2:-}"; shift 2 ;;
        --uninstall)   UNINSTALL=1; shift ;;
        -h|--help)     usage 0 ;;
        *) die "未知参数: $1(用 --help 查看用法)" ;;
    esac
done

if [ "${UNINSTALL:-0}" = "1" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -f "$CONF"
    echo "✅ 已移除 frpc LaunchAgent 与配置(二进制 $BIN 保留,可直接删除)"
    exit 0
fi

[ -n "$SERVER" ] || die "缺少 --server <云服务器公网IP>"
[ -n "$TOKEN" ]  || die "缺少 --token <隧道Token>"
[ "$(uname -s)" = "Darwin" ] || die "此脚本用于 macOS;服务器端请用 deploy/cloud/install-frps.sh"

if [ -z "$LOCAL_PORT" ]; then
    LOCAL_PORT="$(cd "$REPO_DIR" && python3 -c 'import json,sys;print(json.load(open("config.json"))["port"])' 2>/dev/null || echo 8977)"
fi

case "$(uname -m)" in
    arm64)  ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

# ---------------------------------------------------------------- 下载 frpc
if [ -z "$FRP_VERSION" ]; then
    info "查询 frp 最新版本"
    FRP_VERSION="$(curl -fsSL --max-time 15 \
        https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1 || true)"
    FRP_VERSION="${FRP_VERSION:-0.62.1}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PKG="frp_${FRP_VERSION}_darwin_${ARCH}"
URL="${FRP_PKG_URL:-https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}.tar.gz}"

info "下载 frp v${FRP_VERSION} (darwin_${ARCH})"
curl -fL --retry 3 --connect-timeout 10 -o "$TMP/frp.tar.gz" "$URL" \
    || die "下载失败,可手动下载 ${URL} 后解压出 frpc 放到 $BIN"
tar -xzf "$TMP/frp.tar.gz" -C "$TMP"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$(dirname "$LOG")"
install -m 0755 "$TMP/$PKG/frpc" "$BIN"

# ---------------------------------------------------------------- 写入配置
umask 077
cat > "$CONF" <<EOF
# mac-display-remote frpc 配置(由 install-frpc.sh 生成)
serverAddr = "${SERVER}"
serverPort = ${FRP_PORT}

auth.method = "token"
auth.token = "${TOKEN}"

transport.tls.enable = true

[[proxies]]
name = "mac-display-remote"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
remotePort = ${REMOTE_PORT}
EOF
chmod 600 "$CONF"

# ---------------------------------------------------------------- LaunchAgent
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>-c</string>
        <string>${CONF}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 3

if pgrep -f "$BIN -c $CONF" >/dev/null 2>&1; then
    echo "✅ frpc 已启动并注册开机自启(LaunchAgent: $LABEL)"
else
    echo "❌ frpc 未启动,日志末尾:"
    tail -20 "$LOG" 2>/dev/null || true
    exit 1
fi

echo ""
echo "本地服务:  $(curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" >/dev/null 2>&1 && echo '正常' || echo '未响应,请先运行 ./install.sh')"
echo "隧道日志:  $LOG"
echo ""
echo "==================== 完成,记下这两行 ===================="
echo "手机外网访问:  http://${SERVER}:${REMOTE_PORT}"
echo "访问 Token:    $(cd "$REPO_DIR" && python3 -c 'import json;print(json.load(open("config.json"))["token"])' 2>/dev/null || echo '<见 config.json>')"
echo "========================================================="
echo ""
echo "iPhone 首次从上面的外网地址打开控制页,输入 Token 后,"
echo "再点「添加快捷指令」——生成的 Siri 快捷指令会自动指向该外网地址。"
echo "回滚: ./deploy/mac/install-frpc.sh --uninstall"
