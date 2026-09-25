#!/bin/bash
# mac-display-remote 一键安装:注册 LaunchAgent,开机自启、崩溃自动拉起
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.gaomeng.mac-display-remote"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$DIR/logs/mac-display-remote.log"
PY="$(command -v python3 || true)"
PY="${PY:-/usr/bin/python3}"

# 导入 server 模块确保 config.json 已生成(含随机 token),并读出端口与 token
eval "$("$PY" - "$DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import server
print(f'PORT={server.CONFIG["port"]}')
print(f'TOKEN={server.CONFIG["token"]}')
PYEOF
)"

cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$DIR/server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
sleep 1

if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "✅ 服务已启动,并已注册开机自启(LaunchAgent: $LABEL)"
else
    echo "❌ 服务未响应,请查看日志: $LOG"
    echo "   若 macOS 弹出防火墙询问,请选择\"允许\"python3 接受传入连接后重试"
    exit 1
fi

LOCAL_HOST="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || hostname -s)"

echo ""
echo "==================== 安装完成,记下这两行 ===================="
echo "手机访问地址:  http://$LOCAL_HOST.local:$PORT"
echo "访问 Token:    $TOKEN"
echo "============================================================="
echo ""
echo "iPhone 上:Safari 打开上面的地址输入 Token 即可遥控;"
echo "或按 README 配置快捷指令,绑定 Siri 语音控制。"
