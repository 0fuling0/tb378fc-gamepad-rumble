#!/system/bin/sh
# 量一下 bridge 守护进程（及其子进程：awk/date/sleep）的实际 CPU 占用
# 用法：sh measure-cpu.sh <观察秒数>
# 原理：读 /proc/<pid>/stat 的 utime+stime（单位 jiffies，USER_HZ 通常 100），
#       累加整个进程树，除以观察时间和核心数。

DUR=${1:-20}
HZ=100

# 找出 bridge 进程树（bridge.sh + 它的子孙）
collect() {
    echo "$1"
    local kids
    kids=$(for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        ppid=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
        [ "$ppid" = "$1" ] && echo "$p"
    done)
    for k in $kids; do collect "$k"; done
}

tree=$(collect "$BRIDGE_PID" 2>/dev/null | sort -u | tr '\n' ' ')
echo "进程树: $tree"

read_cpu() {
    t=0
    for p in $tree; do
        [ -r "/proc/$p/stat" ] || continue
        # 14/15 = 自身 utime/stime；16/17 = 已回收子进程的 cutime/cstime。
        # 漏掉 16/17 会把 dumpsys（Java，起 JVM）这类子进程的开销全算丢。
        v=$(awk '{print $14+$15+$16+$17}' "/proc/$p/stat" 2>/dev/null)
        [ -n "$v" ] && t=$((t + v))
    done
    echo "$t"
}

c0=$(read_cpu)
echo "开始观察 ${DUR}s（期间请保持手柄静止）..."
sleep "$DUR"
c1=$(read_cpu)

delta=$((c1 - c0))
echo "自身+子进程 CPU 增量: $delta jiffies"
echo "CPU 时间: $(awk -v d="$delta" -v hz="$HZ" 'BEGIN{printf "%.2f", d/hz}') 秒"
echo "占单核: $(awk -v d="$delta" -v hz="$HZ" -v dur="$DUR" 'BEGIN{printf "%.1f%%", d/hz/dur*100}')"
echo "占整机(8核): $(awk -v d="$delta" -v hz="$HZ" -v dur="$DUR" 'BEGIN{printf "%.2f%%", d/hz/dur*100/8}')"
