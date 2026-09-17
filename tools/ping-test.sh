#!/system/bin/sh
echo "=== log 命令可用吗 ==="
command -v log && echo "  可用 ✓" || echo "  ✗ 没有"
echo ""
echo "=== 写一条探针，再用 logcat -s 过滤看能不能读到 ==="
log -t TB378FC_HB "ping-$$"
sleep 1
echo "  --- logcat -d -s TB378FC_HB ---"
logcat -d -v brief -s TB378FC_HB 2>/dev/null | tail -3
echo ""
echo "=== 流式订阅能不能收到（3 秒内）==="
( logcat -v brief -s TB378FC_HB 2>/dev/null | head -2 & ) 
sleep 1
log -t TB378FC_HB "ping2-$$"
sleep 2
pkill -f "logcat -v brief -s TB378FC_HB" 2>/dev/null
echo ""
echo "=== 写一条探针的耗时 ==="
t0=$(date +%s%N); log -t TB378FC_HB "t"; t1=$(date +%s%N)
echo "  $(( (t1-t0)/1000000 )) ms"
