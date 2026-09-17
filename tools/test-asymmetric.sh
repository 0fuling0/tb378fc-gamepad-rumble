#!/system/bin/sh
# 左右幅值不等的工况：验证「解析」和「打包成 9 字节报告」两侧都对。
# 不需要手柄（只解析字符串 + 把报告写到普通文件，不碰 hidraw）。
#
# ⚠️ 下面这几条参数展开表达式是**从 bridge.sh 的 run_logcat 里抄过来的**，
#    改那边的时候要同步改这里（测试脚本故意不 source bridge.sh —— 那会执行它的主流程）。

ok=0; bad=0
chk() { # $1=说明 $2=实际 $3=期望
    if [ "$2" = "$3" ]; then printf "  ✓ %-46s %s\n" "$1" "$2"; ok=$((ok+1))
    else printf "  ✗ %-46s 实际=[%s] 期望=[%s]\n" "$1" "$2" "$3"; bad=$((bad+1)); fi
}

# ---- 和 bridge.sh 里完全一样的解析 ----
parse_lr() {   # 输出 "左 右"
    _ch="${1##*channels=[}"; _ch="${_ch%%]*}"; _ch="${_ch#*: }"
    l="${_ch%%,*}"
    case "$_ch" in
        *,*) _ch="${_ch#*, }"; r="${_ch#*: }"; r="${r%%,*}" ;;
        *)   r="$l" ;;
    esac
    case "$l" in ''|*[!0-9]*) l=0 ;; esac
    case "$r" in ''|*[!0-9]*) r=0 ;; esac
    printf '%s %s' "$l" "$r"
}
parse_l() { parse_lr "$1" | cut -d' ' -f1; }
parse_r() { parse_lr "$1" | cut -d' ' -f2; }
parse_d() { d="${1##*duration=}"; d="${d%%ms*}"; case "$d" in ''|*[!0-9]*) d=0 ;; esac; printf '%s' "$d"; }

# ---- 和 bridge.sh 里完全一样的报告构造 ----
oct() { printf '\\%03o' "$1"; }
report_hex() { # $1=左 $2=右 $3=duration(×10ms) $4=loop
    printf '\003\017\000\000%b%b%b%b\000' \
        "$(oct "$1")" "$(oct "$2")" "$(oct "$3")" "$(oct "$4")" | od -An -tx1 | tr -s ' '
}

echo "=== ① 解析：左右相等（对称）==="
LINE='D/InputReader( 2914): nextStep: sending vibrate deviceId=5, element=[duration=500ms, channels=[0 : 255, 1 : 255]]'
chk "duration" "$(parse_d "$LINE")" "500"
chk "左" "$(parse_l "$LINE")" "255"
chk "右" "$(parse_r "$LINE")" "255"

echo ""
echo "=== ② 解析：左右不等（这次的重点）==="
LINE='D/InputReader( 2914): nextStep: sending vibrate deviceId=5, element=[duration=800ms, channels=[0 : 255, 1 : 64]]'
chk "duration" "$(parse_d "$LINE")" "800"
chk "左（通道 0）" "$(parse_l "$LINE")" "255"
chk "右（通道 1）" "$(parse_r "$LINE")" "64"

echo ""
echo "=== ③ 解析：左弱右强 / 单侧为 0 ==="
L1='nextStep: sending vibrate deviceId=11, element=[duration=1000ms, channels=[0 : 32, 1 : 255]]'
chk "左=32 右=255" "$(parse_l "$L1")/$(parse_r "$L1")" "32/255"
L2='nextStep: sending vibrate deviceId=11, element=[duration=1000ms, channels=[0 : 0, 1 : 255]]'
chk "左=0 右=255" "$(parse_l "$L2")/$(parse_r "$L2")" "0/255"
L3='nextStep: sending vibrate deviceId=11, element=[duration=1000ms, channels=[0 : 255, 1 : 0]]'
chk "左=255 右=0" "$(parse_l "$L3")/$(parse_r "$L3")" "255/0"

echo ""
echo "=== ④ 解析：单通道（框架只报一个通道时的兜底）==="
L4='nextStep: sending vibrate deviceId=11, element=[duration=300ms, channels=[0 : 128]]'
chk "左=128" "$(parse_l "$L4")" "128"
chk "右（单通道 → 镜像到左）" "$(parse_r "$L4")" "128"

echo ""
echo "=== ⑤ 报告字节：左右不等时 9 个字节长什么样 ==="
echo "  格式： [0]=03 [1]=0f [2]=00 [3]=00 [4]=左 [5]=右 [6]=duration [7]=loop [8]=00"
echo ""
printf "  左=255 右=255 → %s\n" "$(report_hex 255 255 50 1)"
printf "  左=255 右=64  → %s\n" "$(report_hex 255 64 50 1)"
printf "  左=0   右=255 → %s\n" "$(report_hex 0 255 50 1)"
printf "  左=255 右=0   → %s\n" "$(report_hex 255 0 50 1)"
printf "  左=32  右=255 → %s\n" "$(report_hex 32 255 50 1)"

echo ""
echo "=== ⑥ 报告长度检查（必须恰好 9 字节）==="
for pair in "255 255" "255 64" "0 255" "255 0" "32 255" "1 1"; do
    set -- $pair
    n=$(printf '\003\017\000\000%b%b%b%b\000' "$(oct "$1")" "$(oct "$2")" "$(oct 50)" "$(oct 1)" | wc -c)
    chk "左=$1 右=$2 的字节数" "$n" "9"
done

echo ""
echo "================ 结果 ================"
echo "  通过 $ok / 失败 $bad"
[ "$bad" -eq 0 ] && echo "  全部通过 ✓" || echo "  有失败 ✗"
