#!/system/bin/sh
M=/data/adb/modules/tb378fc_gamepad_rumble
P=$(ps -A -o PID,ARGS 2>/dev/null | grep "service.sh" | grep -v grep | awk '{print $1}' | head -1)
echo "看护 pid=$P"

echo ""
echo "=== 看护 60 秒的 CPU 增量（含子进程）==="
a=$(awk '{print $14+$15+$16+$17}' /proc/$P/stat)
u0=$(cut -d. -f1 /proc/uptime)
sleep 60
b=$(awk '{print $14+$15+$16+$17}' /proc/$P/stat)
u1=$(cut -d. -f1 /proc/uptime)
d=$((b-a)); dt=$((u1-u0))
echo "  ${d} jiffies / ${dt} 秒 = $((d*10)) ms CPU"
echo "  占单核: $(awk -v d=$d -v t=$dt 'BEGIN{printf "%.2f%%", d*100/(t*100)}')"

echo ""
echo "=== 单次 sh bridge.sh --discover 的耗时（连做 3 次）==="
i=1
while [ $i -le 3 ]; do
    s=$(awk '{print $14+$15+$16+$17}' /proc/self/stat 2>/dev/null)
    t0=$(date +%s%N 2>/dev/null)
    ( cd $M && sh bridge.sh --discover ) >/dev/null 2>&1
    t1=$(date +%s%N 2>/dev/null)
    if [ -n "$t0" ] && [ -n "$t1" ]; then
        echo "    第 $i 次: $(( (t1-t0)/1000000 )) ms（含新起一个 sh 解析 30KB 脚本）"
    fi
    i=$((i+1))
done

echo ""
echo "=== 对照：单次 dumpsys input 的耗时 ==="
i=1
while [ $i -le 3 ]; do
    t0=$(date +%s%N 2>/dev/null)
    dumpsys input >/dev/null 2>&1
    t1=$(date +%s%N 2>/dev/null)
    [ -n "$t0" ] && [ -n "$t1" ] && echo "    第 $i 次: $(( (t1-t0)/1000000 )) ms"
    i=$((i+1))
done

echo ""
echo "=== 便宜的替代判据：只看 sysfs 有没有"带 hidraw 的 uhid 设备" ==="
i=1
while [ $i -le 3 ]; do
    t0=$(date +%s%N 2>/dev/null)
    n=0
    for d in /sys/devices/virtual/misc/uhid/*/; do
        [ -d "$d" ] || continue
        for h in "$d"hidraw/hidraw*; do
            [ -e "$h" ] && n=$((n+1)) && break
        done
    done
    t1=$(date +%s%N 2>/dev/null)
    [ -n "$t0" ] && [ -n "$t1" ] && echo "    第 $i 次: $(( (t1-t0)/1000000 )) ms  （找到 $n 个）"
    i=$((i+1))
done
