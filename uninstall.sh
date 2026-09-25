#!/bin/bash
# mac-display-remote 卸载:移除 LaunchAgent 并停止服务
set -euo pipefail

LABEL="com.gaomeng.mac-display-remote"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl unload "$PLIST_DST" 2>/dev/null; then
    echo "服务已停止"
fi
rm -f "$PLIST_DST"
echo "已从开机自启中移除($PLIST_DST)"
echo "配置与日志保留在原处:config.json / 项目内 logs/mac-display-remote.log"
