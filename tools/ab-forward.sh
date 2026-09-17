#!/system/bin/sh
# A/B 实验：bridge 转发到底需不需要？
#
#   A 组：模块**关闭**（确认 bridge 进程真的没了）→ 让框架发 3 秒满幅震动
#   B 组：模块**打开**（确认 bridge 在跑）      → 让框架发同样的 3 秒满幅震动
#
# 两组都从框架侧触发（cmd vibrator_manager），所以走的是同一条框架路径；
# 唯一区别就是 B 组多了一个 bridge 把"格式正确的报告"补发出去。
# 如果只有 B 组震 → 转发是必需的；如果两组都震 → 转发可以砍掉。
M=/data/adb/modules/tb378fc_gamepad_rumble

show() {
    echo -n "    进程: "
    ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{printf "%s ", $1}'
    echo ""
    echo -n "    bridge.pid=$(cat $M/bridge.pid 2>/dev/null)  lock=$(cat $M/.bridge.lock/pid 2>/dev/null)  "
    echo "config=$(sed -n 's/^FIX_GAMEPAD_RUMBLE=//p' $M/config)"
}

echo "############ A 组：模块关闭 ############"
( cd $M && sh bridge.sh --set FIX_GAMEPAD_RUMBLE 0 ) >/dev/null 2>&1
sleep 4
echo "  --- 关闭后状态（进程应为空、config=0）---"
show
logcat -b all -c 2>/dev/null
echo ""
echo "  >>> 现在发 A 组震动（3 秒满幅）—— 请留意手柄"
cmd vibrator_manager synced oneshot 3000 255 2>&1
A_TS=$(date '+%H:%M:%S')
echo "  A 组发出时间: $A_TS"
sleep 6
echo ""
echo "  --- A 组：框架实际发给谁了 ---"
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c
echo "  --- A 组：模块日志有没有「转发」（应该没有）---"
tail -4 $M/gp.log | sed 's/^/    /'

echo ""
echo "############ B 组：模块打开 ############"
( cd $M && sh bridge.sh --set FIX_GAMEPAD_RUMBLE 1 ) >/dev/null 2>&1
sleep 9
echo "  --- 打开后状态（应有 bridge 在跑）---"
show
logcat -b all -c 2>/dev/null
echo ""
echo "  >>> 现在发 B 组震动（3 秒满幅）—— 请留意手柄"
cmd vibrator_manager synced oneshot 3000 255 2>&1
B_TS=$(date '+%H:%M:%S')
echo "  B 组发出时间: $B_TS"
sleep 6
echo ""
echo "  --- B 组：框架实际发给谁了 ---"
logcat -d -b all -v brief -s InputReader 2>/dev/null | grep -oE "(sending|cancel) vibrate deviceId=[0-9]+" | sort | uniq -c
echo "  --- B 组：模块日志有没有「转发」（应该有）---"
tail -4 $M/gp.log | sed 's/^/    /'

echo ""
echo "############ 汇总 ############"
echo "  A 组（模块关）发出于 $A_TS"
echo "  B 组（模块开）发出于 $B_TS"
echo "  两组相隔约 15 秒，每次都是 3 秒满幅。"
