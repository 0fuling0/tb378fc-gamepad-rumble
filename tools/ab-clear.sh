#!/system/bin/sh
# 清晰版对照实验：两次震动，间隔 8 秒，每次 4 秒满幅
#   第 1 次 = 模块直发（直接写 hidraw）—— **一定会震**，用来建立手感/确认手柄活着
#   第 2 次 = 框架发（模块关闭）      —— 这次是要判定的
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 手柄连接状态（睡了就先按一下手柄任意键）==="
echo -n "    uhid 设备: "; ls -d /sys/devices/virtual/misc/uhid/*/ 2>/dev/null | wc -l
echo -n "    hidraw   : "; ls /dev/hidraw* 2>/dev/null | tr '\n' ' '; echo
echo -n "    dumpsys 里的 Xbox 段: "; dumpsys input 2>/dev/null | grep -c "Xbox Wireless Controller"
echo -n "    模块识别 : "; ( cd $M && sh bridge.sh --discover ) 2>/dev/null | tr '\n' ' '; echo

echo ""
echo "=== 确保模块关闭（转发链路停掉）==="
( cd $M && sh bridge.sh --set FIX_GAMEPAD_RUMBLE 0 ) >/dev/null 2>&1
sleep 4
echo -n "    config="; sed -n 's/^FIX_GAMEPAD_RUMBLE=//p' $M/config
echo -n "    进程: "; ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{printf "%s ", $1}'; echo "(空=已停)"

echo ""
echo "############################################################"
echo "  第 1 次：模块直发（一定会震）—— 4 秒满幅"
echo "  时间 $(date '+%H:%M:%S')"
echo "############################################################"
( cd $M && sh bridge.sh --once 255 255 4000 ) 2>&1 | sed 's/^/    /'

echo ""
echo "  ... 等 8 秒 ..."
sleep 8

echo ""
echo "############################################################"
echo "  第 2 次：框架发（模块关闭）—— 4 秒满幅"
echo "  时间 $(date '+%H:%M:%S')"
echo "############################################################"
logcat -b all -c 2>/dev/null
cmd vibrator_manager synced oneshot 4000 255 >/dev/null 2>&1

sleep 5
echo ""
echo "  --- 这次框架实际发给了谁 ---"
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c | sed 's/^/    /'
echo "  --- 模块日志（应该还是没有「转发」）---"
tail -3 $M/gp.log | sed 's/^/    /'
