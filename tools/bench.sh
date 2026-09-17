#!/system/bin/sh
# 比较几种"拿震动状态"的方式的 CPU 开销
# 关键：dumpsys 是 Java 程序（app_process，每次起 JVM）；logcat 是原生二进制。
# 用 /proc/$$/stat 的 cutime/cstime（已回收子进程）来算，否则子进程开销全丢。

measure() {
    name="$1"; shift
    n="$1"; shift
    s=$(awk '{print $14+$15+$16+$17}' /proc/$$/stat)
    i=0
    while [ "$i" -lt "$n" ]; do
        "$@" >/dev/null 2>&1
        i=$((i + 1))
    done
    e=$(awk '{print $14+$15+$16+$17}' /proc/$$/stat)
    d=$((e - s))
    echo "$name: $n 次共 $d jiffies = $(( d * 10 )) ms  →  每次 $(( d * 10 / n )) ms CPU"
}

measure "dumpsys input                " 10 dumpsys input
measure "logcat -d -t 50 (原生)       " 50 logcat -d -b all -v brief -s InputReader -t 50
measure "logcat -d -T 带时间戳        " 50 logcat -d -b all -v brief -s InputReader -T '01-01 00:00:00.000'
measure "settings get（对照，Java）    " 20 settings get system vibrate_input_devices
