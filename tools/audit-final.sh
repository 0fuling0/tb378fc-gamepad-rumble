#!/system/bin/sh
# 「有手柄」最终测量：开销 + 心跳来源 + 端到端
M=/data/adb/modules/tb378fc_gamepad_rumble

pids() { ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{print $1}'; }

echo "=== ① 那 4 个「低频探针」tag 到底有多安静（20 秒）==="
logcat -b all -c 2>/dev/null
timeout 20 logcat -b all -v brief -s InputReader DisplayManager SurfaceFlinger \
    PowerManagerService BatteryService 2>/dev/null | grep -c "" | sed 's/^/  20 秒收到行数: /'
echo "  （如果接近 0，说明心跳**只能**靠看护的自探针保活）"

echo ""
echo "=== ② 自探针在同样 20 秒里的条数 ==="
timeout 5 logcat -d -b all -v brief -s TB378FC_HB 2>/dev/null | grep -c "TB378FC_HB" | sed 's/^/  logcat 缓存里的探针条数: /'

echo ""
echo "=== ③ 心跳年龄 ==="
hb=$(cat $M/.heartbeat 2>/dev/null); now=$(cut -d. -f1 /proc/uptime)
echo "  心跳=$hb  uptime=$now  年龄=$((now-hb))s"

echo ""
echo "=== ④ 60 秒 CPU 增量（逐个进程）==="
BEFORE=""
for p in $(pids); do BEFORE="$BEFORE $p:$(awk '{print $14+$15+$16+$17}' /proc/$p/stat 2>/dev/null)"; done
u0=$(cut -d. -f1 /proc/uptime)
sleep 60
u1=$(cut -d. -f1 /proc/uptime)
TOTAL=0
for p in $(pids); do
    c=$(awk '{print $14+$15+$16+$17}' /proc/$p/stat 2>/dev/null)
    old=$(echo "$BEFORE" | tr ' ' '\n' | grep "^$p:" | cut -d: -f2)
    [ -n "$old" ] || continue
    d=$((c - old)); TOTAL=$((TOTAL + d))
    printf "  pid=%-6s %4s jiffies = %4s ms   %s\n" "$p" "$d" "$((d*10))" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-50)"
done
echo "  ------------------------------------------------"
printf "  合计 %s jiffies = %s ms / %s 秒\n" "$TOTAL" "$((TOTAL*10))" "$((u1-u0))"
echo "  占单核:     $(awk -v d=$TOTAL -v t=$((u1-u0)) 'BEGIN{printf "%.2f%%", d*100/(t*100)}')"
echo "  占整机(8核): $(awk -v d=$TOTAL -v t=$((u1-u0)) 'BEGIN{printf "%.3f%%", d*100/(t*100*8)}')"

echo ""
echo "=== ⑤ 端到端：框架发一次震动，看模块有没有转发 ==="
logcat -b all -c 2>/dev/null
echo "  >>> 发 2 秒满幅  $(date '+%H:%M:%S')"
cmd vibrator_manager synced oneshot 2000 255 >/dev/null 2>&1
sleep 4
echo "  --- 框架发给谁 ---"
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c | sed 's/^/    /'
echo "  --- 模块日志 ---"
tail -3 $M/gp.log | sed 's/^/    /'

echo ""
echo "=== ⑥ 有没有切到轮询模式 ==="
grep -c "以轮询模式启动 bridge" $M/gp.log 2>/dev/null | sed 's/^/  「以轮询模式启动」出现次数: /'
