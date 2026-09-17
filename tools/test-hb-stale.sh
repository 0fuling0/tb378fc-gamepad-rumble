#!/system/bin/sh
# 验证：read -t 超时唤醒时**不会**刷新心跳（否则订阅真死了心跳也一直新鲜，
# 看护就发现不了、不会切轮询）—— 这是 read -t 方案最关键的风险点。
M=/data/adb/modules/tb378fc_gamepad_rumble
cd "$M" || exit 1

for p in $(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | awk '{print $1}'); do
    kill -9 "-$p" 2>/dev/null; kill -9 "$p" 2>/dev/null
done
sleep 2
rm -f .heartbeat

echo "=== 起 bridge（无手柄 → 只会超时唤醒，不会有真实日志行）==="
setsid /data/adb/ksu/bin/busybox sh bridge.sh >/dev/null 2>&1 </dev/null &
sleep 4
a=$(cat .heartbeat 2>/dev/null); u=$(cut -d. -f1 /proc/uptime)
echo "  第 4 秒：心跳=$a  uptime=$u  年龄=$((u-a))s  ← 启动时写过一次"
sleep 20
b=$(cat .heartbeat 2>/dev/null); u=$(cut -d. -f1 /proc/uptime)
echo "  第 24 秒：心跳=$b  uptime=$u  年龄=$((u-b))s"
echo ""
if [ "$a" = "$b" ]; then
    echo "  ✓ 心跳值没变（${a} → ${b}）—— 超时唤醒**没有**刷新心跳，"
    echo "    订阅真死了时心跳会一直变旧，看护能发现并切轮询。存活检测保住了。"
else
    echo "  ✗ 心跳被刷新了（${a} → ${b}）—— 订阅死了也会显示健康，存活检测失效！"
fi
echo ""
echo "=== 收尾：等它退出 ==="
i=0
while [ $i -lt 40 ]; do
    n=$(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" | grep -v grep | wc -l)
    [ "$n" -eq 0 ] && { echo "  ✓ 第 $((i+24)) 秒：已全部退出"; break; }
    sleep 8; i=$((i+8))
done
[ "$i" -ge 40 ] && echo "  ✗ 没退出"
