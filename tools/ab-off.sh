#!/system/bin/sh
# 只测「模块关闭」这一组：确认 bridge 进程真的没了，再让框架连发 3 次 2 秒满幅
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 1) 关闭模块 ==="
( cd $M && sh bridge.sh --set FIX_GAMEPAD_RUMBLE 0 ) 2>&1 | sed 's/^/    /'
sleep 4

echo ""
echo "=== 2) 确认转发链路真的停了 ==="
echo -n "    config          : "; sed -n 's/^FIX_GAMEPAD_RUMBLE=//p' $M/config
echo -n "    bridge.pid 文件 : "; cat $M/bridge.pid 2>/dev/null; echo "(空=没有)"
echo -n "    单实例锁        : "; cat $M/.bridge.lock/pid 2>/dev/null; echo "(空=没有)"
echo -n "    相关进程        : "
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{printf "%s ", $1}'
echo "(空=全清干净了)"

echo ""
echo "=== 3) 连发 3 次 2 秒满幅（模块关闭状态）==="
logcat -b all -c 2>/dev/null
i=1
while [ $i -le 3 ]; do
    echo "    >>> 第 $i 次  $(date '+%H:%M:%S')"
    cmd vibrator_manager synced oneshot 2000 255 >/dev/null 2>&1
    sleep 4
    i=$((i+1))
done

echo ""
echo "=== 4) 框架实际把它发给了谁 ==="
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c | sed 's/^/    /'

echo ""
echo "=== 5) 模块日志：应该一条「转发」都没有 ==="
tail -5 $M/gp.log | sed 's/^/    /'

echo ""
echo "=== 6) 对照：模块自己的直发（hidraw 直接写，绕过框架）==="
echo "    这一发一定会震（它是模块的 --once）——用来确认手柄本身没问题"
echo "    >>> 直发  $(date '+%H:%M:%S')"
( cd $M && sh bridge.sh --once 255 255 2000 ) 2>&1 | sed 's/^/    /'
