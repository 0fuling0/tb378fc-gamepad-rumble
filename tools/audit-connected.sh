#!/system/bin/sh
# 「手柄连着」状态下的完整开销审计
M=/data/adb/modules/tb378fc_gamepad_rumble

pids() { ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{print $1}'; }

echo "=== ① 进程清单（pid / ppid / 命令行）==="
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | sed 's/^/  /'
echo -n "  进程数: "; pids | wc -l

echo ""
echo "=== ② 模式确认 ==="
echo -n "  bridge 主壳的命令行: "
ps -A -o PID,ARGS 2>/dev/null | grep "bridge.sh" | grep -v grep | grep -v "logcat" | awk '{for(i=2;i<=NF;i++)printf "%s ",$i; print ""}'
echo -n "  logcat 子进程的过滤串: "
ps -A -o PID,ARGS 2>/dev/null | grep "logcat -b all" | grep -v grep | awk '{for(i=5;i<=NF;i++)printf "%s ",$i; print ""}'
echo "  （含 TB378FC_HB = 新订阅串；没有 --poll = logcat 模式）"

echo ""
echo "=== ③ 60 秒 CPU 增量（逐个进程，含子进程）==="
BEFORE=""
for p in $(pids); do
    c=$(awk '{print $14+$15+$16+$17}' /proc/$p/stat 2>/dev/null)
    BEFORE="$BEFORE $p:$c"
done
u0=$(cut -d. -f1 /proc/uptime)
sleep 60
u1=$(cut -d. -f1 /proc/uptime)
TOTAL=0
for p in $(pids); do
    c=$(awk '{print $14+$15+$16+$17}' /proc/$p/stat 2>/dev/null)
    old=$(echo "$BEFORE" | tr ' ' '\n' | grep "^$p:" | cut -d: -f2)
    [ -n "$old" ] || continue
    d=$((c - old))
    TOTAL=$((TOTAL + d))
    cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-52)
    printf "  pid=%-6s %4s jiffies = %4s ms   %s\n" "$p" "$d" "$((d*10))" "$cmd"
done
echo "  ------------------------------------------------"
printf "  合计: %s jiffies = %s ms / %s 秒\n" "$TOTAL" "$((TOTAL*10))" "$((u1-u0))"
echo "  占单核: $(awk -v d=$TOTAL -v t=$((u1-u0)) 'BEGIN{printf "%.2f%%", d*100/(t*100)}')"
echo "  占整机(8核): $(awk -v d=$TOTAL -v t=$((u1-u0)) 'BEGIN{printf "%.3f%%", d*100/(t*100*8)}')"

echo ""
echo "=== ④ 心跳新鲜度（每 20 秒采一次，共 3 次）==="
i=1
while [ $i -le 3 ]; do
    hb=$(cat $M/.heartbeat 2>/dev/null)
    now=$(cut -d. -f1 /proc/uptime)
    echo "  第 $i 次: 心跳=$hb  uptime=$now  年龄=$((now - hb))s（阈值 300s）"
    [ $i -lt 3 ] && sleep 20
    i=$((i+1))
done

echo ""
echo "=== ⑤ 看护的探针有没有真的到达 bridge ==="
echo -n "  最近 60 秒 logcat 里的 TB378FC_HB 行数: "
timeout 5 logcat -d -b all -v brief -s TB378FC_HB 2>/dev/null | grep -c "TB378FC_HB"
echo "  （看护每 30 秒写一条，所以缓存里应该有几条）"
timeout 5 logcat -d -b all -v brief -s TB378FC_HB 2>/dev/null | tail -3 | sed 's/^/    /'

echo ""
echo "=== ⑥ 有没有切到轮询模式 ==="
grep -c "以轮询模式启动 bridge" $M/gp.log 2>/dev/null | sed 's/^/  日志里「以轮询模式启动」出现次数: /'
tail -4 $M/gp.log | sed 's/^/  /'
