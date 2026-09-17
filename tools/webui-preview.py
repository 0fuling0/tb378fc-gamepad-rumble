#!/usr/bin/env python3
"""把 module/webroot/index.html 变成可以在桌面浏览器里直接看的预览页。

为什么要它：WebUI 平时只能在 KernelSU 管理器里打开 —— 改一行样式想看一眼，
就得打包 → 装模块 → 重启设备。这个脚本给页面注入一个假的 ksu.exec
（返回一组像真机一样的 JSON），生成 out/webui-preview-*.html，浏览器直接打开即可，
布局 / 配色 / 交互都能看。

用法：
    python3 tools/webui-preview.py                  # 手柄模块（默认）
    python3 tools/webui-preview.py --target lite    # Lite 模块（对比风格用）
    python3 tools/webui-preview.py --dark           # 强制深色（默认跟随系统）
    python3 tools/webui-preview.py --no-banner      # 不加底部那条"这是预览"提示

注意：注入的只是数据，**不改动页面本身的 HTML/CSS** —— 所以看到的就是真机的样子。
"""
import argparse
import io
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

TARGETS = {
    "rumble": {
        "name": "手柄震动修复",
        "html": ROOT / "module" / "webroot" / "index.html",
        # 真机上 `sh bridge.sh --json` 的输出
        "data": {
            "FIX_GAMEPAD_RUMBLE": 1,
            "RUMBLE_SETTING": "1",
            "BRIDGE_RUNNING": 1,
            "PAD_COUNT": 1,
            "PAD_MAP": "11 /dev/hidraw0",
            "VERSION": "v1.0",
            "MARKERS": "",
        },
        "status": (
            "TB378FC 手柄震动修复  v1.0\n"
            "模块目录: /data/adb/modules/tb378fc_gamepad_rumble\n"
            "\n"
            "本项开关         : 开\n"
            "vibrate_input_devices : 1   （需要是 1）\n"
            "bridge 守护进程  : 运行中 pid=11069\n"
            "识别到的手柄     : 1 个\n"
            "                   deviceId=11  ->  /dev/hidraw0"
        ),
    },
    "lite": {
        "name": "系统修复 Lite",
        "html": (ROOT.parent / "tb378fc-hyperos-fix-lite" / "module" / "webroot" / "index.html"),
        # 真机上 `sh service.sh --json` 的输出
        "data": {
            "FIX_POWERKEEPER": 1,
            "FIX_BPFMON": 1,
            "FIX_TELEPHONY": 1,
            "NEED_APP": 0,
            "VERSION": "v1.0",
            "BPFMON_SVC": "stopped",
            "BPFMON_RUNNING": 0,
            "POWERKEEPER_MOUNTED": 1,
            "POWERKEEPER_SEEN": 1,
            "POWERKEEPER_PAYLOAD": 1,
            "TELEPHONY_DONE": 1,
            "TELEPHONY_STATE": " com.qti.phone:absent",
            "MARKERS": "",
        },
        "status": (
            "TB378FC HyperOS 修复 Lite  v1.0\n"
            "② PowerKeeper 补丁     : 1\n"
            "③ 停 BPF 监视器        : 1\n"
            "④ 停死电话栈           : 1"
        ),
    },
}


def stub_script(data: dict, status: str) -> str:
    payload = json.dumps(data, ensure_ascii=False)
    status_js = json.dumps(status, ensure_ascii=False)
    return (
        "\n<!-- ↓↓↓ 预览用：假的 ksu.exec（真机上是 KernelSU 注入的），下面这行以下都不是页面本身的内容 ↓↓↓ -->\n"
        "<script>\n"
        "(function(){\n"
        "  var OUT = " + payload + ";\n"
        "  var STATUS = " + status_js + ";\n"
        "  function reply(cmd){\n"
        "    if (cmd.indexOf('--json') >= 0)     return JSON.stringify(OUT);\n"
        "    if (cmd.indexOf('--set') >= 0)      return '已写入 1 项（重启设备后由 service.sh 生效）';\n"
        "    if (cmd.indexOf('--once') >= 0)     return '已发送 1 次：左=255 右=255 时长=1000ms';\n"
        "    if (cmd.indexOf('--status') >= 0)   return STATUS;\n"
        "    if (cmd.indexOf('--sepolicy') >= 0) return '';\n"
        "    return '';\n"
        "  }\n"
        "  window.ksu = { exec: function(c){ return Promise.resolve(reply(String(c))); } };\n"
        "})();\n"
        "</script>\n"
    )


def dark_override(css: str) -> str:
    """把页面自己的 `@media (prefers-color-scheme:dark){ :root{...} }` 抽出来，
    去掉 media 条件再追加回去 —— 这样不用改系统主题就能看深色版。
    直接复用页面里的令牌，所以预览的深色和真机深色是同一套值。"""
    m = re.search(r"@media\s*\(prefers-color-scheme:\s*dark\)\s*\{([\s\S]*?)\n\}", css)
    if not m:
        return ""
    return "<style>\n/* 预览用：强制深色（复用页面自己的深色令牌） */\n" + m.group(1) + "\n</style>\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=sorted(TARGETS), default="rumble")
    ap.add_argument("--dark", action="store_true", help="强制深色主题")
    ap.add_argument("--no-banner", action="store_true", help="不加底部那条预览提示")
    ap.add_argument("-o", "--out", help="输出路径（默认 out/webui-preview-<target>.html）")
    args = ap.parse_args()

    t = TARGETS[args.target]
    src = t["html"]
    if not src.is_file():
        print("找不到页面：%s" % src, file=sys.stderr)
        return 1

    html = io.open(src, encoding="utf-8").read()

    # 注入位置：<body> 之后（页面自己的 <script> 在 body 末尾，所以那时 window.ksu 已经在了）
    m = re.search(r"<body[^>]*>", html)
    if not m:
        print("页面里找不到 <body>", file=sys.stderr)
        return 1
    html = html[:m.end()] + stub_script(t["data"], t["status"]) + html[m.end():]

    if args.dark:
        css = re.search(r"<style>([\s\S]*?)</style>", html)
        if css:
            html = html.replace("</head>", dark_override(css.group(1)) + "</head>", 1)

    if not args.no_banner:
        html = html.replace(
            "</body>",
            '<div style="margin:0 14px 20px;padding:10px 12px;border:1px dashed rgba(128,128,128,.5);'
            'border-radius:10px;font-size:11.5px;line-height:1.5;opacity:.8">'
            '<b>这是桌面预览</b>（' + t["name"] + '）：'
            '数据是脚本塞进去的假数据，<b>页面本身的 HTML/CSS 一个字没改</b>，'
            '所以看到的就是真机上的样子。真机上由 KernelSU 注入 <code>ksu.exec</code>。'
            '</div>\n</body>',
            1,
        )

    out = Path(args.out) if args.out else (ROOT / "out" / ("webui-preview-%s.html" % args.target))
    out.parent.mkdir(parents=True, exist_ok=True)
    io.open(out, "w", encoding="utf-8", newline="\n").write(html)
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
