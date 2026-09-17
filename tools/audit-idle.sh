#!/system/bin/sh
# 空闲（无手柄）开销：瞬时采样 + 开机至今的平均
M=/data/adb/modules/tb378fc_gamepad_rumble

P=$(ps -A -o PID,ARGS 2>/dev/null | grep "service.sh" | grep -v grep | awk '{print $1}' | head -1)
[ -n "$P" ] || { echo "没找到看护进程"; exit 1; }

cpuof() { awk '{print $14+$15+$16+$17}' /proc/$P/stat; }

echo "=== 进程清单 ==="
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | sed 's/^/  /'
echo -n "  进程数: "
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | wc -l

echo ""
echo "=== ① 开机至今的平均（含开机时的一次性工作）==="
tot=$(cpuof)
up=$(cut -d. -f1 /proc/uptime)
printf "  看护 pid=%s  累计 %s jiffies = %s ms / uptime %s 秒\n" "$P" "$tot" "$((tot*10))" "$up"
echo "  平均: $(awk -v d=$tot -v t=$up 'BEGIN{printf "%.3f%%", d*100/(t*100)}') 单核  （整机 8 核 $(awk -v d=$tot -v t=$up 'BEGIN{printf "%.4f%%", d*100/(t*100*8)}')）"

echo ""
echo "=== ② 瞬时采样 60 秒 × 2 ==="
i=1
while [ $i -le 2 ]; do
    a=$(cpuof); u0=$(cut -d. -f1 /proc/uptime)
    sleep 60
    b=$(cpuof); u1=$(cut -d. -f1 /proc/uptime)
    d=$((b-a)); dt=$((u1-u0))
    printf "  第 %s 次: %s jiffies = %s ms / %s 秒 → %s 单核（整机 %s）\n" \
        "$i" "$d" "$((d*10))" "$dt" \
        "$(awk -v d=$d -v t=$dt 'BEGIN{printf "%.3f%%", d*100/(t*100)}')" \
        "$(awk -v d=$d -v t=$dt 'BEGIN{printf "%.4f%%", d*100/(t*100*8)}')"
    i=$((i+1))
done

echo ""
echo "=== ③ 看护在空闲时每 20 秒做一次什么（fork 账单）==="
echo "    sleep 20                        → 1 次 fork（~3ms）"
echo "    has_hidraw（纯 sysfs glob）      → 0 次 fork（~2ms）"
echo "    enabled → cfg_read（内建 read）  → 0 次 fork"
echo "    ping_hb                          → 只在「确认有手柄之后」才写，空闲时不写"
echo "    → 合计约 5ms / 20 秒 ≈ 0.025% 单核"

echo ""
echo "=== ④ 日志尾部（看护状态）==="
tail -4 $M/gp.log | sed 's/^/  /'
