#!/system/bin/sh
# 测试：logcat 模式下，没有手柄时 bridge 会不会自己退出（并且不留孤儿 logcat）
M=/data/adb/modules/tb378fc_gamepad_rumble
cd "$M" || exit 1

echo "=== 0) 前置确认：现在没有手柄 ==="
node=$(sh bridge.sh --discover 2>/dev/null | head -1 | awk '{print $2}')
echo "  discover → [${node:-（空）}]"
[ -n "$node" ] && { echo "  ⚠️ 有手柄，这个测的是「无手柄退出」，先把手柄断开"; exit 1; }

echo ""
echo "=== 1) 清场 ==="
for p in $(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e service.sh -e "logcat -b all" | grep -v grep | awk '{print $1}'); do
    kill -9 "-$p" 2>/dev/null; kill -9 "$p" 2>/dev/null
done
sleep 2
echo -n "  剩余进程: "
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e service.sh -e "logcat -b all" | grep -v grep | wc -l

echo ""
echo "=== 2) 起 bridge（默认 = logcat 模式）==="
: > gp.log
setsid /data/adb/ksu/bin/busybox sh bridge.sh >/dev/null 2>&1 </dev/null &
sleep 3
echo "  刚起来的进程："
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | sed 's/^/    /'
echo -n "  进程数: "
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | wc -l
echo "  （用 FIFO 方案后应该只有 2 个：bridge 主壳 + 后台 logcat，没有管道子壳）"

echo ""
echo "=== 3) 等它自己退出（最多 90 秒，每 10 秒看一次）==="
i=0
while [ $i -lt 90 ]; do
    sleep 10; i=$((i+10))
    n=$(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | wc -l)
    echo "    第 ${i}s：进程数=$n"
    [ "$n" -eq 0 ] && { echo "    ✓ 已全部退出（含 logcat，没有孤儿）"; break; }
done
[ "$i" -ge 90 ] && echo "    ✗ 90 秒了还没退出"

echo ""
echo "=== 4) 日志 ==="
cat gp.log | sed 's/^/  /'

echo ""
echo "=== 5) 收尾检查 ==="
echo -n "  FIFO 残留: "; ls "$M/.lcpipe" 2>/dev/null || echo "（无，已清理 ✓）"
echo -n "  pidfile/锁残留: "; ls "$M/bridge.pid" "$M/.bridge.lock" 2>/dev/null || echo "（无，已清理 ✓）"
echo -n "  最终进程数: "; ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e service.sh -e "logcat -b all" | grep -v grep | wc -l
