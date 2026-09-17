#!/usr/bin/env bash
# TB378FC 手柄震动修复 —— 构建（KernelSU 模块包）
#
#   ./build.sh          自检 + 打包
#   ./build.sh --clean  删掉 out/
#
# 产物：out/tb378fc_gamepad_rumble-v<版本>.zip
#
# 这个模块是**纯 shell**（没有任何需要编译的东西），所以构建只需要 python3 + git，
# 不需要 Android SDK / NDK / JDK。打包用本仓库自带的 tools/pack_zip.py。
set -euo pipefail

if HERE_TMP="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null)"; then
    HERE="$HERE_TMP"
else
    HERE="$(cd "$(dirname "$0")" && pwd)"
fi
MODULE="$HERE/module"
OUT="$HERE/out"
TOOLS="$HERE/tools"

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$OUT"
    echo "cleaned"
    exit 0
fi

MOD_ID=$(sed -n 's/^id=//p' "$MODULE/module.prop")
MOD_VER=$(sed -n 's/^version=//p' "$MODULE/module.prop")
[ -n "$MOD_ID" ] && [ -n "$MOD_VER" ] || { echo "module.prop 里读不到 id/version" >&2; exit 1; }

echo "== $MOD_ID $MOD_VER"

# ---------- ① 脚本自检 ----------
echo "== 脚本自检（语法 / 未定义函数 / WebUI 渲染与交互）"
for f in "$MODULE"/*.sh; do
    sh -n "$f" || { echo "语法错误: $f" >&2; exit 1; }
    echo "  ok $(basename "$f")"
done

if [ -f "$TOOLS/check-helpers.py" ]; then
    python3 "$TOOLS/check-helpers.py" "$MODULE"/*.sh
fi

# WebUI 自检：用极简 DOM 桩把 webroot/index.html 的渲染与交互真跑一遍
# （"拨开关必须只触发一次 --set" 这类约束就在里面断言）。没装 node 就跳过。
if command -v node >/dev/null 2>&1; then
    node "$TOOLS/webui-selftest.js" >/dev/null || {
        echo "WebUI 自检失败，重跑看细节：node tools/webui-selftest.js" >&2
        exit 1
    }
    echo "  webroot/index.html 自检通过"
else
    echo "  跳过 WebUI 自检（没找到 node）"
fi

# 模块必需文件齐不齐 —— 少一个装到设备上就是静默不工作
for f in module.prop config bridge.sh parse-input.awk service.sh customize.sh \
         uninstall.sh webroot/index.html; do
    [ -f "$MODULE/$f" ] || { echo "模块里缺少 $f" >&2; exit 1; }
done
echo "  模块必需文件齐全"

# 行尾必须是 LF —— 脚本要 adb push 到设备上跑，CRLF 会让 mksh 直接报
# "inaccessible or not found" / "syntax error: unexpected '&&'"，看起来像脚本写错了。
python3 - "$MODULE" <<'PY'
import pathlib, sys
bad = []
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    if p.is_file() and p.suffix in ('.sh', '.prop', '.html') or p.name == 'config':
        if b'\r\n' in p.read_bytes():
            bad.append(str(p))
if bad:
    print("以下文件含 CRLF，必须先转成 LF：", file=sys.stderr)
    for b in bad: print("  " + b, file=sys.stderr)
    sys.exit(1)
print("  行尾检查通过（全部 LF）")
PY

# ---------- ② 打包 ----------
echo "== 打包"
mkdir -p "$OUT"
ZIP="$OUT/${MOD_ID}-${MOD_VER}.zip"
rm -f "$ZIP"

# 权限位必须从 git index 读（Windows 上 stat 读不出执行位），所以直接对 module/ 打包。
# pack_zip.py 会顺手把文本文件的行尾归一化成 LF，并跳过运行期产物。
if [ -f "$TOOLS/pack_zip.py" ]; then
    python3 "$TOOLS/pack_zip.py" "$MODULE" "$ZIP"
elif command -v zip >/dev/null 2>&1; then
    ( cd "$MODULE" && zip -q -r -X "$ZIP" . -x '*.log' -x '.*' )
else
    echo "既没有 tools/pack_zip.py 也没有 zip 命令" >&2
    exit 1
fi

echo
echo "完成：$ZIP"
echo "刷入：把 zip 丢给 KernelSU 管理器（或 ksud module install），重启。"
