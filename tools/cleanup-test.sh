#!/system/bin/sh
# 清理测试残留：所有 logcat 读者 + 所有 gp-test 下的 bridge 进程
# 注意：不能把匹配串直接写进 adb shell 的命令行 —— 那样脚本/命令自己也会被匹配到
# （踩过两次：pkill -f bridge.sh 把执行它的 shell 杀了；for 循环扫 cmdline 同理）。
# 所以固定用这个脚本，匹配串在文件里。

echo "--- 清理前 ---"
ps -A -o PID,ARGS 2>/dev/null | grep -E "[l]ogcat|[b]ridge.sh" | head -20

pkill -x logcat 2>/dev/null
sleep 1

for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$p/cmdline" ] || continue
    [ "$p" = "$$" ] && continue
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
        *"bridge.sh"*) kill -9 "$p" 2>/dev/null ;;
    esac
done
sleep 1

echo "--- 清理后 ---"
n1=$(ps -A -o ARGS 2>/dev/null | grep -c "[l]ogcat")
n2=$(ps -A -o ARGS 2>/dev/null | grep -c "[b]ridge.sh")
echo "剩余 logcat: $n1   剩余 bridge: $n2"
