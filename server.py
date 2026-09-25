#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mac-display-remote 服务端

局域网内通过手机(浏览器 / iOS 快捷指令)控制 Mac 显示器的熄屏与亮屏。
只关闭/点亮显示器,系统与正在运行的任务不受影响。

仅依赖 Python 3 标准库,无第三方包;兼容 macOS 系统自带的 Python 3.9。
"""

import ctypes
import json
import os
import plistlib
import secrets
import socket
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
INDEX_PATH = BASE_DIR / "static" / "index.html"

PMSET = "/usr/bin/pmset"
CAFFEINATE = "/usr/bin/caffeinate"

STATUS_TEXT = {True: "屏幕已熄灭", False: "屏幕点亮中", None: "状态未知"}


# ---------------------------------------------------------------- 配置

def load_config() -> dict:
    """读取 config.json;首次运行自动生成(含随机 token),权限收紧为 600。"""
    defaults = {"host": "0.0.0.0", "port": 8977, "token": ""}
    if CONFIG_PATH.exists():
        try:
            saved = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            return {**defaults, **saved}
        except (json.JSONDecodeError, OSError) as exc:
            print(f"[warn] 读取 {CONFIG_PATH} 失败({exc}),使用默认配置")
            return {**defaults, "token": secrets.token_urlsafe(24)}
    cfg = {**defaults, "token": secrets.token_urlsafe(24)}
    try:
        CONFIG_PATH.write_text(
            json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        os.chmod(CONFIG_PATH, 0o600)
    except OSError as exc:
        print(f"[warn] 写入 {CONFIG_PATH} 失败({exc})")
    return cfg


CONFIG = load_config()


# ---------------------------------------------------------------- 屏幕状态

_cg = None


def _coregraphics():
    global _cg
    if _cg is None:
        _cg = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics"
        )
        _cg.CGMainDisplayID.restype = ctypes.c_uint32
        _cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
        _cg.CGDisplayIsAsleep.restype = ctypes.c_int
    return _cg


def display_is_asleep():
    """True=显示器睡眠中,False=点亮中,None=查询失败。"""
    try:
        cg = _coregraphics()
        return bool(cg.CGDisplayIsAsleep(cg.CGMainDisplayID()))
    except Exception as exc:  # 没有 GUI 会话等场景下 CoreGraphics 不可用
        print(f"[warn] 查询屏幕状态失败: {exc}")
        return None


# ---------------------------------------------------------------- 动作

def run_cmd(args) -> bool:
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            print(f"[error] {' '.join(args)} 退出码 {proc.returncode}: {proc.stderr.strip()}")
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"[error] 执行 {' '.join(args)} 失败: {exc}")
        return False


def display_sleep() -> bool:
    # 只让显示器睡眠,系统保持唤醒,正在跑的任务不受影响
    return run_cmd([PMSET, "displaysleepnow"])


def display_wake() -> bool:
    # caffeinate -u 向系统声明一次"用户活跃",系统随之点亮显示器;
    # -t 3 让断言保持 3 秒,不等待其结束以免阻塞 HTTP 响应
    try:
        subprocess.Popen(
            [CAFFEINATE, "-u", "-t", "3"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except OSError as exc:
        print(f"[error] 启动 {CAFFEINATE} 失败: {exc}")
        return False


def system_sleep() -> bool:
    # 整机睡眠(任务会暂停),供用户主动触发,默认不自动使用
    return run_cmd([PMSET, "sleepnow"])


def local_address() -> str:
    host = socket.gethostname().split(".")[0]
    return f"{host}.local"


# ---------------------------------------------------------------- Siri 快捷指令

# 手机端一键安装的快捷指令:服务端生成 → shortcuts CLI 签名 → 浏览器经
# shortcuts://import-shortcut 引导"快捷指令"App 下载导入,token 直接写入请求头。
SHORTCUT_DEFS = {
    "sleep": {"name": "Mac 熄屏", "path": "/api/display/sleep",
              "color": 4282601983, "glyph": 61553},
    "wake": {"name": "Mac 亮屏", "path": "/api/display/wake",
             "color": 4274264319, "glyph": 61440},
}

_signed_cache = {}
_sign_lock = threading.Lock()


class ShortcutError(Exception):
    pass


def _shortcut_action_download(url: str) -> dict:
    # iOS 26 已不识别独立的"URL"动作(is.workflow.actions.geturl),
    # 故接口地址直接内联进"获取 URL 内容"的 WFURL 文本参数,单动作最稳
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
        "WFWorkflowActionParameters": {
            "WFURL": {
                "Value": {"string": url},
                "WFSerializationType": "WFTextTokenString",
            },
            "WFHTTPMethod": "POST",
            "WFHTTPHeaders": {
                "Value": {
                    "WFDictionaryFieldValueItems": [
                        {
                            "WFItemType": 0,
                            "WFKey": {
                                "Value": {"string": "X-Auth-Token"},
                                "WFSerializationType": "WFTextTokenString",
                            },
                            "WFValue": {
                                "Value": {"string": CONFIG["token"]},
                                "WFSerializationType": "WFTextTokenString",
                            },
                        }
                    ]
                },
                "WFSerializationType": "WFDictionaryFieldValue",
            },
        },
    }


def _unsigned_shortcut(kind: str, base_url: str) -> bytes:
    spec = SHORTCUT_DEFS[kind]
    workflow = {
        "WFWorkflowClientVersion": "2038.0.2.4",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": spec["color"],
            "WFWorkflowIconGlyphNumber": spec["glyph"],
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["NCWidget", "WatchKit"],
        "WFWorkflowInputContentItemClasses": [
            "WFAppStoreAppContentItem", "WFGenericFileContentItem",
            "WFImageContentItem", "WFPDFContentItem",
            "WFRichTextContentItem", "WFStringContentItem", "WFURLContentItem",
        ],
        "WFQuickActionSurfaces": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowActions": [
            _shortcut_action_download(f"{base_url}{spec['path']}"),
        ],
    }
    return plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY)


def signed_shortcut(kind: str, base_url: str) -> bytes:
    """生成并签名快捷指令文件(iOS 15+ 只认签名文件),结果按 token+地址缓存。

    base_url 取自下载请求的 Host 头:手机从哪个地址打开控制页,快捷指令
    内的接口地址就指向哪个地址,IP 访问与 .local 域名访问都能正常使用。
    """
    cache_key = (kind, CONFIG["token"], base_url)
    with _sign_lock:
        if cache_key in _signed_cache:
            return _signed_cache[cache_key]
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "unsigned.shortcut")
            dst = os.path.join(tmp, "signed.shortcut")
            with open(src, "wb") as fh:
                fh.write(_unsigned_shortcut(kind, base_url))
            proc = subprocess.run(
                ["/usr/bin/shortcuts", "sign", "--mode", "anyone",
                 "-i", src, "-o", dst],
                capture_output=True, text=True, timeout=30,
            )
            stderr = "\n".join(
                line for line in proc.stderr.splitlines()
                if "attribute string flag" not in line  # CLI 自身的 ObjC 噪音
            ).strip()
            if proc.returncode != 0 or not os.path.exists(dst):
                raise ShortcutError(stderr or f"shortcuts sign 退出码 {proc.returncode}")
            with open(dst, "rb") as fh:
                data = fh.read()
        _signed_cache[cache_key] = data
        return data


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "MacDisplayRemote/1.0"
    protocol_version = "HTTP/1.1"

    def _send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self):
        body = INDEX_PATH.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_download(self, filename: str, body: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header(
            "Content-Disposition",
            f"attachment; filename*=UTF-8''{quote(filename)}",
        )
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        return bool(CONFIG["token"]) and self.headers.get("X-Auth-Token", "") == CONFIG["token"]

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path in ("/", "/index.html"):
            return self._send_html()
        if path == "/health":  # 连通性探测,不含敏感信息,无需鉴权
            return self._send_json(200, {"ok": True, "service": "mac-display-remote"})
        if path == "/api/status":
            if not self._authorized():
                return self._send_json(401, {"error": "unauthorized"})
            asleep = display_is_asleep()
            return self._send_json(200, {
                "display_asleep": asleep,
                "status_text": STATUS_TEXT[asleep],
                "hostname": local_address(),
            })
        if path.startswith("/api/shortcut/"):
            # 快捷指令文件会被"快捷指令"App 直接下载,无法附加请求头,
            # 故改用查询参数携带 token;该 URL 仅在本机控制页内生成,不外泄
            token = parse_qs(query).get("t", [""])[0]
            if not token or token != CONFIG["token"]:
                return self._send_json(401, {"error": "unauthorized"})
            filename = unquote(path[len("/api/shortcut/"):])
            if "熄屏" in filename or filename == "sleep":
                kind = "sleep"
            elif "亮屏" in filename or filename == "wake":
                kind = "wake"
            else:
                return self._send_json(404, {"error": "not found"})
            try:
                host = self.headers.get("Host", "").strip()
                if not host:  # HTTP/1.1 必带 Host,此处仅兜底
                    host = f"{local_address()}:{CONFIG['port']}"
                data = signed_shortcut(kind, f"http://{host}")
            except ShortcutError as exc:
                print(f"[error] 快捷指令签名失败: {exc}")
                return self._send_json(503, {"error": "shortcut_sign_failed", "detail": str(exc)})
            return self._send_download(f"{SHORTCUT_DEFS[kind]['name']}.shortcut", data)
        return self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not self._authorized():
            return self._send_json(401, {"error": "unauthorized"})
        if path == "/api/display/sleep":
            return self._send_json(200, {"ok": display_sleep(), "action": "display_sleep"})
        if path == "/api/display/wake":
            return self._send_json(200, {"ok": display_wake(), "action": "display_wake"})
        if path == "/api/system/sleep":
            return self._send_json(200, {"ok": system_sleep(), "action": "system_sleep"})
        return self._send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")


def main():
    host, port = CONFIG["host"], int(CONFIG["port"])
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"mac-display-remote 已启动: http://{host}:{port}")
    print(f"手机访问地址: http://{local_address()}:{port}")
    print(f"Token: {CONFIG['token']}  (保存在 {CONFIG_PATH})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("已停止")
        server.server_close()


if __name__ == "__main__":
    main()
