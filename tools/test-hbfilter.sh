#!/system/bin/sh
# 用 bridge 那条**完整**过滤串起一个订阅，然后写一条探针，看能不能收到
OUT=/data/local/tmp/hbfilter.out
rm -f $OUT
# 完全照抄 bridge.sh 的过滤串
logcat -b all -v brief -T 1 -s InputReader DisplayManager SurfaceFlinger \
    PowerManagerService BatteryService TB378FC_HB > $OUT 2>/dev/null &
LP=$!
sleep 2
log -t TB378FC_HB "probe-from-test-$$"
sleep 2
kill -9 $LP 2>/dev/null
pkill -f "TB378FC_HB" 2>/dev/null

echo "=== 订阅收到的行数 ==="
wc -l < $OUT
echo ""
echo "=== 里面有没有我们的探针 ==="
if grep -q "probe-from-test-$$" $OUT; then
    echo "  ✓ 收到了"
    grep "probe-from-test-$$" $OUT | sed 's/^/    /'
else
    echo "  ✗ 没收到"
fi
echo ""
echo "=== 前 5 行（看看低频探针有没有在说话）==="
head -5 $OUT | sed 's/^/    /'
rm -f $OUT
