#!/system/bin/sh
# 端到端测试：让框架下发一次震动，看它有没有发给手柄、模块有没有转发
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 清 logcat ==="
logcat -b all -c
echo "done"

echo ""
echo "=== 触发一次震动（框架路径）==="
cmd vibrator_manager synced oneshot 1500 255 2>&1
sleep 3

echo ""
echo "=== 框架实际发给了哪些 deviceId ==="
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -E "vibrate deviceId=" | tail -8
echo "(空 = 框架没发任何震动)"

echo ""
echo "=== 统计：各 deviceId 的 sending / cancel ==="
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c

echo ""
echo "=== vibrator_manager 的最近震动记录 ==="
dumpsys vibrator_manager 2>/dev/null | grep -iE "recent|IGNORED|FORWARDED|input device|Vibrators:" | head -20

echo ""
echo "=== 模块日志（看有没有『转发 -> deviceId=11』）==="
tail -10 "$M/gp.log" 2>/dev/null
