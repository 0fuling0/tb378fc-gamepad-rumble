#!/system/bin/sh
# 卸载时执行：把 bridge 守护进程收干净
#
# 为什么必须显式杀：bridge 是 setsid 起来的，不受 init 管理，
# 卸载模块不会自动带走它 —— 留着它会继续往一个已经不存在的手柄节点写数据。
# ⚠️ 不能只写 MODDIR=${0%/*} —— 用 `sh bridge.sh` 这样不带路径地调用时，
# $0 里没有斜杠，${0%/*} 会原样返回 "bridge.sh"，后面所有路径就全错了。
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(pwd) ;;
esac

if [ -f "$MODDIR/bridge.pid" ]; then
    pid=$(cat "$MODDIR/bridge.pid" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ] && grep -q "bridge.sh" "/proc/$pid/cmdline" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
fi

# service.sh 的看护循环也要停（它按 disable 标记退出，所以这里补一个）
if [ -f "$MODDIR/service.pid" ]; then
    pid=$(cat "$MODDIR/service.pid" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
fi

# 兜底：按 cmdline 扫一遍（pidfile 可能已经过期）。
# ⚠️ 匹配串必须用 "bridge.sh"，不能用模块目录名 —— 守护进程是用
# `/system/bin/sh <模块目录>/bridge.sh` 起的，只有 "bridge.sh" 一定出现在 cmdline 里；
# 而模块目录名是 tb378fc_gamepad_rumble（下划线），按 "gamepad-rumble" 匹配会漏掉。
# 另外：本脚本自己的 cmdline 里不含 "bridge.sh"，所以不会自杀。
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$p/cmdline" ] || continue
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "bridge.sh"; then
        kill -9 "$p" 2>/dev/null
    fi
done

# 注意：Settings.System.vibrate_input_devices 故意**不还原**。
# 它是 Android 的标准设置项（大多数设备默认就是 1），本机是被移植包留成了未设置。
# 留着它没有副作用；如果哪天内核的 hid-microsoft 报告顺序被修好，它反而是必需的。
# 想还原成移植包原状：settings delete system vibrate_input_devices
