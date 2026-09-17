#!/system/bin/sh
M=/data/adb/modules/tb378fc_gamepad_rumble
logcat -b all -c 2>/dev/null
echo "已清空 logcat，等 45 秒（看护每 30 秒一条探针）…"
sleep 45

echo ""
echo "=== ① logcat 里的探针（应该有 1~2 条）==="
logcat -d -b all -v brief -s TB378FC_HB 2>/dev/null | tail -4 | sed 's/^/  /'
echo -n "  条数: "
logcat -d -b all -v brief -s TB378FC_HB 2>/dev/null | grep -c "TB378FC_HB"

echo ""
echo "=== ② 心跳 ==="
hb=$(cat $M/.heartbeat 2>/dev/null); now=$(cut -d. -f1 /proc/uptime)
echo "  心跳=$hb  uptime=$now  年龄=$((now-hb))s（阈值 300s）"

echo ""
echo "=== ③ gp.log 尾部（不该再出现「-t TB378FC_HB ping」）==="
tail -6 $M/gp.log | sed 's/^/  /'
echo -n "  日志里「-t TB378FC_HB」的条数（应为 0）: "
grep -c -- "-t TB378FC_HB" $M/gp.log 2>/dev/null

echo ""
echo "=== ④ 进程（应为 4 个）==="
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | sed 's/^/  /'
