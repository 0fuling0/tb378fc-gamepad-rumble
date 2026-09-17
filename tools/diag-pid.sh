#!/system/bin/sh
# 手柄模块的 pidfile / 进程树诊断
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 模块目录里的运行时文件 ==="
ls -la "$M" | grep -E 'pid|lock|heartbeat|hidmap|\.state|gp\.log'
echo ""
echo "--- bridge.pid  ---"; cat "$M/bridge.pid" 2>&1
echo "--- service.pid ---"; cat "$M/service.pid" 2>&1
echo "--- .bridge.lock/pid ---"; cat "$M/.bridge.lock/pid" 2>&1
echo "--- .heartbeat ---"; cat "$M/.heartbeat" 2>&1
echo "--- uptime ---"; cut -d. -f1 /proc/uptime

echo ""
echo "=== 所有相关进程（PID/PPID/PGID/SID）==="
ps -A -o PID,PPID,PGID,SID,ARGS 2>/dev/null | grep -e bridge.sh -e logcat -e service.sh | grep -v grep

echo ""
echo "=== 完整 gp.log ==="
cat "$M/gp.log"
