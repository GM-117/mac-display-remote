#!/bin/bash
# mac-display-remote 云端中转:一键安装 frp 服务端(frps)
#
# 在华为云 Linux 服务器上以 root 运行:
#   sudo ./install-frps.sh
#
# 作用:开放一个自定义公网端口,把请求通过隧道转发到家里 Mac 上运行的
# server.py(frp 客户端由 Mac 主动外连,路由器无需端口映射)。
#
# 可调环境变量:
#   FRP_PORT     frp 控制端口(客户端连接用),默认 47000
#   ENTRY_PORT   对外访问端口(手机访问用),默认 18977
#   FRP_VERSION  指定版本,默认取 GitHub 最新 release
set -euo pipefail

FRP_PORT="${FRP_PORT:-47000}"
ENTRY_PORT="${ENTRY_PORT:-18977}"
FRP_VERSION="${FRP_VERSION:-}"
CONF_DIR="/etc/frp"
BIN="/usr/local/bin/frps"
SERVICE="/etc/systemd/system/frps.service"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(uname -s)" = "Linux" ] || die "此脚本用于 Linux 服务器;macOS 端请用 deploy/mac/install-frpc.sh"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo $0"
command -v systemctl >/dev/null || die "未检测到 systemd,请手动部署"
command -v curl >/dev/null || die "缺少 curl,请先安装"
command -v tar >/dev/null || die "缺少 tar,请先安装"
command -v openssl >/dev/null || die "缺少 openssl,请先安装"

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

if [ -z "$FRP_VERSION" ]; then
    info "查询 frp 最新版本"
    FRP_VERSION="$(curl -fsSL --max-time 15 \
        https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1 || true)"
    FRP_VERSION="${FRP_VERSION:-0.62.1}"   # API 不通时的兜底版本
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PKG="frp_${FRP_VERSION}_linux_${ARCH}"
URL="${FRP_PKG_URL:-https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}.tar.gz}"

info "下载 frp v${FRP_VERSION} (${ARCH})"
curl -fL --retry 3 --connect-timeout 10 -o "$TMP/frp.tar.gz" "$URL" \
    || die "下载失败,可手动下载 ${URL} 后放到本机重试"
tar -xzf "$TMP/frp.tar.gz" -C "$TMP"
install -m 0755 "$TMP/$PKG/frps" "$BIN"

# 访问凭据:客户端与服务端共用,token 泄露才可能被蹭隧道,故用 64 位十六进制
TOKEN="$(openssl rand -hex 32)"

id frp >/dev/null 2>&1 || useradd --system --user-group --no-create-home --shell /sbin/nologin frp

install -d -m 0755 "$CONF_DIR"
cat > "$CONF_DIR/frps.toml" <<EOF
# mac-display-remote frp 服务端配置(由 install-frps.sh 生成)
bindAddr = "0.0.0.0"
bindPort = ${FRP_PORT}

# 对外监听地址:0.0.0.0 表示代理端口直接暴露公网。
# 若后续在 nginx 后面做限流,改成 "127.0.0.1" 并调整 Mac 端 remotePort。
proxyBindAddr = "0.0.0.0"

auth.method = "token"
auth.token = "${TOKEN}"

# 客户端必须走 TLS(仅加密 frp 自身的控制/数据隧道)
transport.tls.force = true

# 只允许本服务使用的端口,防止 token 意外泄露后被用来开别的端口
allowPorts = [{ start = ${ENTRY_PORT}, end = ${ENTRY_PORT} }]
maxPortsPerClient = 1

log.to = "console"
log.level = "info"
log.maxDays = 7
EOF
chown frp:frp "$CONF_DIR/frps.toml"
chmod 600 "$CONF_DIR/frps.toml"

cat > "$SERVICE" <<EOF
[Unit]
Description=frp server for mac-display-remote
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=frp
Group=frp
Restart=on-failure
RestartSec=5s
ExecStart=${BIN} -c ${CONF_DIR}/frps.toml
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
sleep 1

# 系统防火墙(华为云还需在控制台安全组放行,两处都要开)
open_firewall_port() {
    local p="$1"
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 已放行 TCP ${p}"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        info "ufw 已放行 TCP ${p}"
    fi
}
open_firewall_port "$FRP_PORT"
open_firewall_port "$ENTRY_PORT"

systemctl is-active --quiet frps || {
    echo "--- journalctl -u frps ---"
    journalctl -u frps -n 30 --no-pager || true
    die "frps 启动失败"
}

PUBLIC_IP="$( { curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 5 https://ifconfig.me/ip 2>/dev/null \
    || curl -fsSL --max-time 5 https://4.ipw.cn 2>/dev/null; } | tr -d '\n' )"
PUBLIC_IP="${PUBLIC_IP:-<服务器公网IP>}"

cat <<EOF

✅ frps 已安装并开机自启(systemd: frps)

==================== 记下这三行 ====================
服务器公网 IP:   ${PUBLIC_IP}
frp 控制端口:    ${FRP_PORT}      (安全组需放行)
对外访问端口:    ${ENTRY_PORT}      (安全组需放行)
隧道 Token:      ${TOKEN}
===================================================

接下来:
1. 在华为云控制台 → 服务器安全组里放行 TCP ${FRP_PORT} 和 TCP ${ENTRY_PORT}
2. 到 Mac 上运行:
   ./deploy/mac/install-frpc.sh --server ${PUBLIC_IP} --token ${TOKEN}
3. 手机任意网络访问: http://${PUBLIC_IP}:${ENTRY_PORT}

提示: 公网入口是明文 HTTP,访问 Token 会以明文经过网络。
      个人使用风险可控;若以后有已备案域名,可在本机加 nginx + HTTPS。
EOF
