# 外网访问部署记录(华为云 frp)

- 状态:✅ 已上线(2026-11-18)
- 目标:人在外网(iPhone 蜂窝数据 / 其他 Wi-Fi)也能控制 Mac 显示器熄屏 / 亮屏
- 方案:Mac 保留控制服务,华为云只做 frp 反向代理入口
- 组件版本:frp v0.72.0

## 拓扑

```
iPhone(任意网络)
      │  http://115.120.210.69:18977
      ▼
华为云 ECS(frps,仅转发)
      ▲
      │  frp 隧道(TCP 47000,TLS + token 鉴权)
      │  Mac 主动外连,无需公网 IP / 路由器端口映射
      ▼
Mac 上的 server.py(127.0.0.1:8977)
      │
      └─> pmset displaysleepnow / caffeinate -u / CGDisplayIsAsleep
```

> 为什么不能把服务直接部署到云服务器:熄屏、亮屏、状态查询分别依赖 macOS 的
> `pmset`、`caffeinate` 和 CoreGraphics;云服务器是 Linux,只能做转发入口。

## 实际部署参数

### 云端

| 项目 | 值 |
|---|---|
| 主机 | `115.120.210.69`(Ubuntu 24.04.5 LTS,x86_64) |
| frps 二进制 | `/usr/local/bin/frps` |
| 配置 | `/etc/frp/frps.toml`(属主 `frp:frp`,权限 600) |
| 服务 | systemd `frps`,开机自启、失败自动重启 |
| 控制端口 | TCP 47000 |
| 对外端口 | TCP 18977 |
| 放行 | 华为云安全组 + ufw 均已放行 47000/18977 |

关键配置项:

```toml
bindPort = 47000
proxyBindAddr = "0.0.0.0"
auth.method = "token"
transport.tls.force = true          # 客户端必须走 TLS
allowPorts = [{ start = 18977, end = 18977 }]
maxPortsPerClient = 1
```

### Mac 端

| 项目 | 值 |
|---|---|
| frpc 二进制 | `~/.local/bin/frpc` |
| 配置 | `~/.config/frp/frpc.toml`(权限 600) |
| 常驻 | LaunchAgent `com.gaomeng.mac-display-remote-frpc`(KeepAlive) |
| 本地端口 | `127.0.0.1:8977`(原有 server.py) |
| 远端端口 | 18977 |

原有的 `com.gaomeng.mac-display-remote` LaunchAgent 不变,局域网入口继续可用。

### 公网入口

```
http://115.120.210.69:18977
```

访问 Token 在 Mac 项目根目录 `config.json`,**不要提交到仓库**。
Siri 快捷指令需要从公网地址打开控制页后重新生成——快捷指令内嵌地址取自
下载请求的 Host 头,因此会自动指向公网入口。

## 验证记录(2026-11-18)

| 检查项 | 命令 / 方式 | 结果 |
|---|---|---|
| 云端服务 | `systemctl is-active frps` | `active` |
| 云端监听 | `ss -lntp \| grep -E ':(47000\|18977)'` | frps 监听 47000、18977 |
| 隧道登录 | `journalctl -u frps` | Mac 客户端 login success,proxy start success |
| 健康检查 | `curl http://115.120.210.69:18977/health` | `{"ok": true, ...}` |
| 屏幕状态 | `curl -H "X-Auth-Token: …" …/api/status` | 返回 `display_asleep` 与状态文案 |
| 写操作 | `POST …/api/display/wake` | `{"ok": true, "action": "display_wake"}` |
| 控制页 | `GET …/` | 200 `text/html` |
| PWA 清单 | `GET …/manifest.webmanifest` | 200 `application/manifest+json` |
| 快捷指令 | `GET …/api/shortcut/sleep?t=…` | 200,21,980B 签名文件 |
| Host 生效 | 同路径分别带真实 / 伪造 Host 请求 | 签名文件 SHA-256 不同,证明内嵌地址随访问地址变化 |
| 日志脱敏 | 请求快捷指令后检查 Mac 日志 | 请求行不含 `?t=<token>` |

## 日常运维

```bash
# 云端
systemctl status frps
journalctl -u frps -f

# Mac 端
launchctl list | grep frpc
tail -f logs/frpc.log
launchctl kickstart -k gui/$(id -u)/com.gaomeng.mac-display-remote-frpc
```

排障顺序:Mac 本机 `curl http://127.0.0.1:8977/health` → `logs/frpc.log` 是否
login success → 云端 `journalctl -u frps` 是否收到连接 → 手机访问
`http://115.120.210.69:18977/health`。

## 回滚

```bash
# 只撤 Mac 端隧道,局域网访问不受影响
./deploy/mac/install-frpc.sh --uninstall

# 云端彻底停用(如需)
sudo systemctl disable --now frps
```

## 安全与限制

- 公网入口为明文 HTTP,访问 Token 会明文经过网络;有已备案域名后建议加
  nginx/Caddy + HTTPS。可选加固配置见 `deploy/cloud/nginx-mac-display.conf`。
- 服务器当前仍允许 root 密码登录(fail2ban 活跃)。建议改为 SSH 密钥登录并关闭
  `PasswordAuthentication`。
- Mac 必须保持开机联网;熄屏不影响网络。合盖外接显示器需接电源,整机睡眠后
  隧道断开,任何入口都无法唤醒。
- LaunchAgent 在用户登录后启动;Mac 重启后需完成登录才会恢复隧道。
- 国内服务器从 GitHub 下载 frp 可能很慢:可先在本地下载,再用
  `FRP_PKG_URL=file:///path/to/frp.tar.gz` 执行安装脚本。
