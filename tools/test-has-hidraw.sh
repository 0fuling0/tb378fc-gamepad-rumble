#!/system/bin/sh
# 验证 has_hidraw 的 glob 逻辑：负例（现在没手柄）和正例（造一棵和真机一样的树）
# 说明：hidraw0 在 sysfs 里是个**目录**，所以 [ -e ] 对文件/目录都成立 —— 假树也照这个造。
test_has_hidraw() {
    for _h in "$1"/*/hidraw/hidraw*; do
        [ -e "$_h" ] && return 0
    done
    return 1
}

echo "=== 负例：真的 uhid 目录（现在没手柄）==="
if test_has_hidraw /sys/devices/virtual/misc/uhid; then
    echo "  返回 0（有）✗ 不该有"
else
    echo "  返回 1（没有）✓"
fi

echo ""
echo "=== 负例：空目录 ==="
rm -rf /data/local/tmp/fakeuhid; mkdir -p /data/local/tmp/fakeuhid
if test_has_hidraw /data/local/tmp/fakeuhid; then echo "  返回 0 ✗"; else echo "  返回 1 ✓"; fi

echo ""
echo "=== 负例：uhid 设备但没有 hidraw 子节点（比如某些 HID 没输出报告通道）==="
mkdir -p "/data/local/tmp/fakeuhid/0005:1234:5678.0001"
if test_has_hidraw /data/local/tmp/fakeuhid; then echo "  返回 0 ✗"; else echo "  返回 1 ✓"; fi

echo ""
echo "=== 正例：造一棵和真机 Xbox 手柄一样的树 ==="
mkdir -p "/data/local/tmp/fakeuhid/0005:045E:0B13.0001/hidraw/hidraw0"
echo "  （真机上的路径长这样："
echo "     /sys/devices/virtual/misc/uhid/0005:045E:0B13.0001/hidraw/hidraw0）"
if test_has_hidraw /data/local/tmp/fakeuhid; then echo "  返回 0（有）✓"; else echo "  返回 1 ✗ 不该没有"; fi

echo ""
echo "=== 正例：多设备 + 只有其中一个带 hidraw ==="
mkdir -p "/data/local/tmp/fakeuhid/0005:ABCD:EF01.0001"
if test_has_hidraw /data/local/tmp/fakeuhid; then echo "  返回 0（有）✓"; else echo "  返回 1 ✗"; fi

echo ""
echo "=== 真机 uhid 目录现在长什么样 ==="
for d in /sys/devices/virtual/misc/uhid/*/; do
    [ -d "$d" ] || continue
    echo "  $d"
    ls "$d" 2>/dev/null | sed 's/^/      /'
done

rm -rf /data/local/tmp/fakeuhid
