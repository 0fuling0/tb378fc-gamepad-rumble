#!/system/bin/sh
# 诊断 gamepad-rumble 的看护进程卡在哪
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "================ 相关进程 ================"
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -E "[s]ervice.sh|[b]ridge.sh|[l]ogcat|[d]iscover"

echo ""
echo "================ 看护进程状态 ================"
found=0
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
        *gamepad_rumble/service.sh*)
            found=1
            echo "  pid=$p  state=$(awk '{print $3}' "/proc/$p/stat")  wchan=$(cat "/proc/$p/wchan" 2>/dev/null)"
            echo "  命令行: $c"
            echo "  子进程:"
            for k in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
                [ "$(awk '{print $4}' "/proc/$k/stat" 2>/dev/null)" = "$p" ] || continue
                echo "    $k: $(tr '\0' ' ' < "/proc/$k/cmdline" 2>/dev/null)"
            done
            ;;
    esac
done
[ "$found" = 0 ] && echo "  ✗ 看护进程已经不在了（service.sh 退出了）"

echo ""
echo "================ 手工跑 --discover ================"
cd "$M" || exit 1
out=$(sh ./bridge.sh --discover 2>&1)
echo "  输出: [$out]"
echo "  rc=$?"

echo ""
echo "================ 手工跑 service.sh 的一段逻辑 ================"
# 模拟看护的第一步
pads=$(sh ./bridge.sh --discover 2>/dev/null)
if [ -z "$pads" ]; then
    echo "  pads 为空 → 看护会走 sleep CHECK_SECONDS 分支"
else
    echo "  pads=[$pads] → 看护会去启动 bridge"
fi

echo ""
echo "================ 配置 ================"
cat "$M/config" 2>/dev/null | grep -vE '^\s*#' | grep -v '^$'

echo ""
echo "================ 完整日志 ================"
cat "$M/gp.log" 2>/dev/null
