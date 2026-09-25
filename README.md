# mac-display-remote 🖥️📱

局域网内用 iPhone 遥控 Mac 显示器的**熄屏 / 亮屏**。

人在客厅或床上,Mac 在书房跑任务:不想专门走过去关屏幕,手机点一下"熄屏",任务照常跑;想回电脑前看结果之前,手机点一下"亮屏"。也可以绑定 Siri,说一句"嘿 Siri,关闭电脑屏幕"。

## 原理

与 ToDesk / 向日葵的"远程黑屏 / 屏幕唤醒"同源:电脑端常驻一个轻量服务,收到指令后调用系统接口控制显示器,只是去掉了画面传输,因此极其轻量(纯 Python 标准库,零第三方依赖)。

| 诉求 | 实现 |
|---|---|
| 熄屏但不打断任务 | `pmset displaysleepnow` — 只关显示器,进程继续运行 |
| 亮屏 | `caffeinate -u` — 向系统声明一次"用户活跃",系统点亮显示器 |
| 查看屏幕当前状态 | `CGDisplayIsAsleep()`(CoreGraphics) |
| 服务常驻 | launchd LaunchAgent:开机自启 + 崩溃自动拉起 |

> 注意区分:**本工具控制的是"显示器"**,不是系统睡眠。熄屏后系统与网络照常工作,这正是"跑任务时关屏幕"的正确姿势;"系统睡眠"是另一个接口(会暂停任务),只在你想让它睡时主动触发。

## 快速开始(电脑端)

```bash
cd mac-display-remote
./install.sh
```

脚本会:生成随机 token(写入 `config.json`)→ 注册 LaunchAgent → 启动服务 → 自检,最后打印**手机访问地址**和**访问 Token**,记下来。

> Token 首次生成后**固定不变**:保存在 `config.json` 中,重启、开机自启都不会更换,手机端只需输入一次。

> 首次启动若 macOS 弹出"是否允许 python3 接受传入网络连接",点"允许"。

## 手机端使用

### 方式 A:浏览器(零安装)

iPhone Safari 打开安装脚本打印的地址(形如 `http://你的Mac.local:8977`),首次输入 Token,即可熄屏 / 亮屏 / 查看屏幕状态,页面每 5 秒自动刷新状态。

### 方式 B:iOS 快捷指令 + Siri(推荐)

手机 Safari 打开控制页(需已输入 Token),点击「添加『Mac 熄屏』」/「添加『Mac 亮屏』」,快捷指令文件会自动下载(页面已预生成,基本秒下),然后:

1. 点 Safari 地址栏旁的**下载图标**,点按刚下载的文件(或打开「文件」App →「下载项」)
2. 在预览页点右下角**添加快捷指令**

Token 已自动写入快捷指令内,无需手动填。之后对 Siri 说:

> "嘿 Siri,Mac 熄屏" / "嘿 Siri,Mac 亮屏"

**原理**:服务端实时生成快捷指令文件(获取 URL 内容 → POST 对应接口),用 macOS 自带的 `shortcuts sign` 命令签名(iOS 15+ 只接受签名快捷指令)。快捷指令文件里内嵌了 Token,下载接口本身仍需 Token 鉴权,请勿把带 `?t=` 的完整链接发给他人。

> 注:曾实现过 `shortcuts://import-shortcut` 一键跳转导入,但 iOS 26 起苹果禁用了该入口(快捷指令 App 报"URL 无效"),故改为下载后从「文件」导入,走系统通用通道,更稳定。

<details>
<summary>从「文件」导入失败?手动创建(备选)</summary>

1. 打开"快捷指令"App → 右上角 `+` 新建
2. 添加操作 **"获取 URL 内容"**,URL 填 `http://你的Mac.local:8977/api/display/sleep`
3. 展开该操作的"显示更多":方法选 **POST**,在"请求头"中添加一条:
   - 键:`X-Auth-Token`　值:你的 Token
4. 命名为"Mac 熄屏"
5. 亮屏同理,URL 换成 `/api/display/wake`,命名"Mac 亮屏"

</details>

### API 一览

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/` | - | 手机控制页 |
| GET | `/health` | - | 连通性探测 |
| GET | `/api/status` | ✅ | 屏幕状态(`display_asleep`: true/false) |
| POST | `/api/display/sleep` | ✅ | 熄屏(任务继续跑) |
| POST | `/api/display/wake` | ✅ | 亮屏(停在锁屏界面) |
| POST | `/api/system/sleep` | ✅ | 系统睡眠(任务暂停,慎用) |
| GET | `/api/shortcut/<名称>.shortcut?t=<token>` | 查询参数 | 下载签名的 Siri 快捷指令文件(`sleep`/`wake` 别名可用) |

鉴权方式:请求头 `X-Auth-Token: <token>`(快捷指令下载接口用查询参数 `?t=<token>`)。

## 手动运行(调试)

```bash
python3 server.py   # 前台运行,Ctrl+C 停止
```

## 常见问题

- **亮屏后停在锁屏界面?** 正常现象,熄屏触发了系统的锁定策略。安全起见建议保持,人在电脑前解锁即可;想远程"看到桌面内容"属于屏幕串流需求,直接用 ToDesk 更合适。
- **手机打不开页面?** ① 确认手机与 Mac 在同一 WiFi;② 个别路由器开启了"AP 隔离"会拦截设备互访,需在路由器后台关闭;③ `.local` 域名解析失败时,可在"系统设置 → Wi-Fi → 详细信息"里查 Mac 的局域网 IP,直接用 IP 访问。
- **想改端口或 Token?** 编辑 `config.json` 后重启服务:
  `launchctl kickstart -k gui/$(id -u)/com.gaomeng.mac-display-remote`
- **Token 每次启动会变吗?** 不会。Token 只在首次运行(无 `config.json`)时随机生成并写入 `config.json`,之后固定不变;只有删除 / 清空 `config.json`(下次启动重新生成)、文件损坏,或手动编辑其中的 `token` 字段时才会变化。
- **合盖使用注意?** 合盖外接显示器(clamshell)时请保持外接电源,否则系统会整体睡眠、服务失联。这也是把"系统睡眠"设计为主动触发接口的原因——平时只熄屏,想让它睡再让它睡。
- **卸载?** `./uninstall.sh`,配置与日志会保留。

## 目录结构

```
mac-display-remote/
├── server.py          # 服务端:HTTP API + 控制页(仅标准库)
├── static/index.html  # 手机控制页
├── install.sh         # 一键安装(LaunchAgent 开机自启)
├── uninstall.sh       # 卸载
├── config.json        # 运行时自动生成:端口 + token(勿提交)
├── logs/              # 服务日志(mac-display-remote.log,勿提交)
└── README.md
```

日志:项目内 `logs/mac-display-remote.log`。每个请求都会记录(含每次启动打印的 Token),页面停留时每 5 秒轮询一次,约每天 1 MB,过大可直接删除,不影响运行。

## Roadmap

- Phase 2:监控指定任务,跑完自动熄屏 / 主动系统睡眠;锁屏联动策略
- Phase 3:屏幕串流(不建议自己做,现有远程软件已够用)
