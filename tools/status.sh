#!/system/bin/sh
# 上机状态速查（避免 adb 多层引号把 grep 表达式吃掉）
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 开关 ==="
echo -n "vibrate_input_devices = "; settings get system vibrate_input_devices

echo ""
echo "=== 进程 ==="
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -e bridge.sh -e logcat | grep -v grep

echo ""
echo "=== 模块日志（尾部）==="
tail -8 "$M/gp.log" 2>/dev/null || echo "(没有日志)"

echo ""
echo "=== 心跳 / uptime ==="
echo -n "心跳: "; cat "$M/.heartbeat" 2>/dev/null; echo -n "  uptime: "; cut -d. -f1 /proc/uptime
echo -n "bridge.pid: "; cat "$M/bridge.pid" 2>/dev/null; echo

echo ""
echo "=== 识别到的手柄 ==="
cd "$M" 2>/dev/null && sh bridge.sh --discover 2>&1

echo ""
echo "=== 手柄是否连着 ==="
echo -n "uhid 设备: "; ls -d /sys/devices/virtual/misc/uhid/*/ 2>/dev/null | wc -l
echo -n "hidraw: "; ls /dev/hidraw* 2>/dev/null | tr '\n' ' '; echo
echo -n "Vibrator Input Mapper 段数: "; dumpsys input 2>/dev/null | grep -c "Vibrator Input Mapper"

echo ""
echo "=== 手柄段的 SysfsRootPath / Sources ==="
dumpsys input 2>/dev/null | grep -B2 -A12 "Xbox Wireless" | grep -E "Device [0-9]+:|SysfsRootPath:|Sources:" | head -12

echo ""
echo "=== 配置 ==="
cat "$M/config" 2>/dev/null | grep -v '^#' | grep -v '^$'
