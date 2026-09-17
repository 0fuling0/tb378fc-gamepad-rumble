#!/system/bin/sh
# 守护进程审计：模块到底起了几个进程、各自干什么、吃多少 CPU
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 模块相关进程（含父子关系）==="
ps -A -o PID,PPID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | while read -r pid ppid rest; do
    # 每个进程的累计 CPU（utime+stime，单位 jiffies=10ms）
    c=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    wc=$(cat "/proc/$pid/wchan" 2>/dev/null)
    printf "  pid=%-6s ppid=%-6s cpu=%-5s jiffies rss=%-7s state=%s wchan=%s\n" "$pid" "$ppid" "${c:-?}" "${rss:-?}kB" "$st" "$wc"
    printf "        %s\n" "$rest"
done

echo ""
echo "=== 进程数 ==="
ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | wc -l

echo ""
echo "=== 各进程打开的关键 fd（看谁在干什么）==="
for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep -e bridge.sh -e "logcat -b all" -e service.sh | grep -v grep | awk '{print $1}'); do
    echo "  --- pid=$pid  $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-70)"
    ls -l /proc/$pid/fd 2>/dev/null | awk '{print "      " $9, $10, $11}' | head -8
done

echo ""
echo "=== uptime（用来折算 CPU 占比）==="
cut -d. -f1 /proc/uptime

echo ""
echo "=== 能不能用 FIFO（省掉管道子壳的前提）==="
command -v mkfifo && echo "  mkfifo 可用 ✓" || echo "  ✗ 没有 mkfifo"

echo ""
echo "=== 系统里一共有多少进程（对比用）==="
ls /proc 2>/dev/null | grep -cE '^[0-9]+$'
