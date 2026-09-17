#!/system/bin/sh
# 采集"手柄识别"需要的数据
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "================ 当前映射（应该只有手柄）================"
cd "$M" || exit 1
sh ./bridge.sh --discover
echo "--- json ---"
sh ./bridge.sh --json

echo ""
echo "================ 所有 uhid 设备 ================"
for d in /sys/devices/virtual/misc/uhid/*/; do
    n=$(head -1 "$d"input/input*/name 2>/dev/null)
    [ -n "$n" ] || continue
    h=$(ls -d "$d"hidraw/hidraw* 2>/dev/null | head -1)
    echo "  name=[$n]"
    echo "    dir=$d"
    echo "    hidraw=[$h]"
done

echo ""
echo "================ InputReader 各设备的 Sources ================"
dumpsys input 2>/dev/null | awk '
    /^  Device [0-9]+: / { printf "\n  %s\n", $0; next }
    /^    Sources: /       { print "   ", $0 }
    /SysfsRootPath:/      { print "   ", $0 }
'

echo ""
echo "================ 各 input 的 FF 能力 ================"
for i in /sys/class/input/input*/; do
    n=$(cat "$i"name 2>/dev/null)
    f=$(cat "$i"capabilities/ff 2>/dev/null)
    echo "  $(basename "$i") [$n]"
    echo "    ff=[$f]"
done

echo ""
echo "================ 平板触感设备（不该被映射）================"
echo "  qcom-hv-haptics 的 SysfsRootPath 下有没有 hidraw："
for d in /sys/devices/platform/soc/*/*/*/qcom,hv-haptics@f000; do
    [ -d "$d" ] || continue
    echo "    $d"
    echo "    hidraw 子目录: [$(ls -d "$d"/hidraw/hidraw* 2>/dev/null | head -1)]"
done
