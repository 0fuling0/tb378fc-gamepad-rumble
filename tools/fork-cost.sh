#!/system/bin/sh
# 量这个设备上"起一个进程"到底多贵 —— 看护每 5 秒要 fork 两次（sleep + cat）
cpu() { awk '{print $14+$15+$16+$17}' /proc/$$/stat; }

echo "=== 20 次 fork sleep 0 ==="
a=$(cpu); i=0; while [ $i -lt 20 ]; do sleep 0; i=$((i+1)); done; b=$(cpu)
echo "  $(( (b-a)*10 )) ms / 20 次 = $(( (b-a)*10/20 )) ms 每次"

echo ""
echo "=== 20 次 fork cat /proc/uptime ==="
a=$(cpu); i=0; while [ $i -lt 20 ]; do c=$(cat /proc/uptime); i=$((i+1)); done; b=$(cpu)
echo "  $(( (b-a)*10 )) ms / 20 次 = $(( (b-a)*10/20 )) ms 每次"

echo ""
echo "=== 20 次 shell 内建 read（对照）==="
a=$(cpu); i=0; while [ $i -lt 20 ]; do read -r x _ < /proc/uptime; i=$((i+1)); done; b=$(cpu)
echo "  $(( (b-a)*10 )) ms / 20 次 = $(( (b-a)*10/20 )) ms 每次"

echo ""
echo "=== 20 次 fork /system/bin/log -t T x ==="
a=$(cpu); i=0; while [ $i -lt 20 ]; do /system/bin/log -t TB_FORKCOST x >/dev/null 2>&1; i=$((i+1)); done; b=$(cpu)
echo "  $(( (b-a)*10 )) ms / 20 次 = $(( (b-a)*10/20 )) ms 每次"

echo ""
echo "=== 看护的 60 秒 CPU（复测一次）==="
P=$(ps -A -o PID,ARGS 2>/dev/null | grep "service.sh" | grep -v grep | awk '{print $1}' | head -1)
a=$(awk '{print $14+$15+$16+$17}' /proc/$P/stat)
u0=$(cut -d. -f1 /proc/uptime)
sleep 60
b=$(awk '{print $14+$15+$16+$17}' /proc/$P/stat)
u1=$(cut -d. -f1 /proc/uptime)
echo "  pid=$P  $(( (b-a)*10 )) ms / $((u1-u0)) 秒 = $(awk -v d=$((b-a)) -v t=$((u1-u0)) 'BEGIN{printf "%.2f%%", d*100/(t*100)}') 单核"
echo ""
echo "  看护的内层循环每 5 秒做这些（数一下 fork）："
echo "    sleep 5        → 1 次 fork"
echo "    cat .heartbeat → 1 次 fork"
echo "    每 6 轮 ping_hb → 1 次 fork"
echo "  → 每分钟约 24 次 fork"
