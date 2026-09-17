#!/system/bin/sh
M=/data/adb/modules/tb378fc_gamepad_rumble
echo "=== 并发调用 discover / --json（各 6 个同时跑）—— 看会不会出现重复条目 ==="
i=0
while [ $i -lt 6 ]; do
    ( cd $M && sh bridge.sh --discover >/dev/null 2>&1 ) &
    ( cd $M && sh bridge.sh --json >/dev/null 2>&1 ) &
    i=$((i+1))
done
wait
echo "  --- 并发跑完后的映射文件 ---"
cat $M/.hidmap 2>/dev/null | sed 's/^/    /'
echo -n "  行数（应为 1）: "; wc -l < $M/.hidmap 2>/dev/null
echo ""
echo "  --- --json 的 PAD_COUNT ---"
( cd $M && sh bridge.sh --json ) 2>/dev/null | sed 's/^/    /'
echo ""
echo "=== 再连跑 3 轮，看是否稳定 ==="
n=1
while [ $n -le 3 ]; do
    i=0
    while [ $i -lt 4 ]; do
        ( cd $M && sh bridge.sh --discover >/dev/null 2>&1 ) &
        i=$((i+1))
    done
    wait
    echo -n "    第 $n 轮 行数="; wc -l < $M/.hidmap 2>/dev/null
    n=$((n+1))
done
echo ""
echo "=== 残留临时文件（应为空）==="
ls -la $M/ | grep -E "\.devs|\.hidmap\." ; echo "(空=没有残留)"
