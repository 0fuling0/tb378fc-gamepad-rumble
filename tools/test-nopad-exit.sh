#!/system/bin/sh
M=/data/adb/modules/tb378fc_gamepad_rumble
cd $M

echo "=== 清场：停掉现有的 bridge 和看护 ==="
for p in $(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e service.sh | grep -v grep | awk '{print $1}'); do
    kill -9 "-$p" 2>/dev/null; kill -9 "$p" 2>/dev/null
done
sleep 2
echo -n "  剩余进程: "; ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | wc -l

echo ""
echo "=== 手工起一个 bridge（当前没有手柄，应该在 ~30 秒后自己退出）==="
: > gp.log
setsid /data/adb/ksu/bin/busybox sh bridge.sh >/dev/null 2>&1 </dev/null &
sleep 5
echo -n "  起后 5 秒的进程数: "; ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | wc -l

echo "  等待退出（最多 60 秒）…"
i=0
while [ $i -lt 60 ]; do
    n=$(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | wc -l)
    [ "$n" -eq 0 ] && { echo "  ✓ 第 $i 秒：bridge 已退出"; break; }
    sleep 5; i=$((i+5))
done
[ "$i" -ge 60 ] && echo "  ✗ 60 秒了还在跑（没退出）"

echo ""
echo "=== 日志 ==="
cat gp.log | sed 's/^/  /'
