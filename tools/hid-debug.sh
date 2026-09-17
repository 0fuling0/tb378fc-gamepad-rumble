#!/system/bin/sh
# 关键实验：关掉模块（确认 bridge 真的没了）后，框架自己发的那份报告能不能让手柄震？
#
# 思路：/sys/kernel/debug/hid/<dev>/events 会把 HID 的 INPUT/OUTPUT 报告都打出来，
# 里面有 OUTPUT 报告 —— 也就是内核驱动实际写给手柄的字节。能看到它就能和模块
# 自己发的那 9 字节逐字节对比，从而判断"驱动那份到底对不对"。
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 有没有 hid debugfs（能看 HID 报告字节）==="
ls -d /sys/kernel/debug/hid/*/ 2>/dev/null | head -20
echo "(空=内核没开 CONFIG_HID_DEBUG / debugfs 没挂)"

echo ""
echo "=== debugfs 挂了吗 ==="
mount 2>/dev/null | grep -i debugfs
echo "(空=没挂)"

echo ""
echo "=== 手柄对应的 hid 设备 ==="
for d in /sys/kernel/debug/hid/*/; do
    [ -d "$d" ] || continue
    n=$(cat "$d/uevent" 2>/dev/null | grep -i "HID_NAME" )
    echo "  $d  $n"
done
