#!/system/bin/sh
# 验证 WebUI 开关"即时生效"（bridge.sh --set → service.sh --apply）
# 重点是复现之前那个 bug：快速连拨开关后看护进入"每 25 秒重启一次"的死循环。
M=/data/adb/modules/tb378fc_gamepad_rumble

state() {
    echo "  --- 状态 ---"
    echo -n "    bridge.pid=$(cat $M/bridge.pid 2>/dev/null)  "
    echo -n "lock=$(cat $M/.bridge.lock/pid 2>/dev/null)  "
    echo -n "service.pid=$(cat $M/service.pid 2>/dev/null)  "
    echo "心跳=$(cat $M/.heartbeat 2>/dev/null)  uptime=$(cut -d. -f1 /proc/uptime)"
    echo -n "    进程: "
    ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{printf "%s ", $1}'
    echo ""
    echo -n "    config: "; grep '^FIX_GAMEPAD_RUMBLE=' $M/config
    echo -n "    --json: "; (cd $M && sh bridge.sh --json 2>/dev/null)
    echo ""
}

set_sw() {
    echo "  → sh bridge.sh --set FIX_GAMEPAD_RUMBLE $1"
    (cd $M && sh bridge.sh --set FIX_GAMEPAD_RUMBLE "$1" 2>&1 | sed 's/^/      /')
}

echo "=========== ① 初始（开机自动起来的）==========="
state

echo "=========== ② 关掉 ==========="
set_sw 0
sleep 3
state

echo "=========== ③ 再打开 ==========="
set_sw 1
sleep 5
state

echo "=========== ④ 快速连拨 4 次（复现之前那个 bug）==========="
set_sw 0; sleep 1
set_sw 1; sleep 1
set_sw 0; sleep 1
set_sw 1
echo "  （等 60 秒，看会不会出现「每 25 秒重启一次」）"
sleep 60
state

echo "=========== ⑤ 日志（关键：不该有反复的「以 logcat 模式启动 bridge」）==========="
tail -25 $M/gp.log

echo ""
echo "=========== ⑥ 重启次数统计 ==========="
echo -n "  日志里「以 logcat 模式启动 bridge」出现次数: "
grep -c "以 logcat 模式启动 bridge" $M/gp.log
echo -n "  日志里「已有 bridge 在跑」出现次数（应尽量少）: "
grep -c "已有 bridge 在跑" $M/gp.log
