#!/system/bin/sh
M=/data/adb/modules/tb378fc_gamepad_rumble
echo "=== 手柄还连着吗 ==="
echo -n "  uhid 设备数: "; ls -d /sys/devices/virtual/misc/uhid/*/ 2>/dev/null | wc -l
echo -n "  hidraw: "; ls /dev/hidraw* 2>/dev/null | tr '\n' ' '; echo
echo -n "  dumpsys 里的 Xbox 段: "; dumpsys input 2>/dev/null | grep -c "Xbox Wireless Controller"
echo -n "  discover: "; ( cd $M && sh bridge.sh --discover ) 2>/dev/null | tr '\n' ' '; echo "(空=没手柄)"
echo ""
echo "=== 看护的完整 CPU（含子进程）==="
for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{print $1}'); do
  awk -v p=$pid '{printf "  pid=%s utime=%s stime=%s cutime=%s cstime=%s 合计=%s jiffies\n", p, $14, $15, $16, $17, $14+$15+$16+$17}' /proc/$pid/stat 2>/dev/null
done
echo -n "  uptime: "; cut -d. -f1 /proc/uptime
echo ""
echo "=== 日志尾部 ==="
tail -6 $M/gp.log
