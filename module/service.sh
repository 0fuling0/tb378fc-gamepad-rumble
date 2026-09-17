#!/system/bin/sh
# TB378FC 手柄震动修复 —— 开机入口（KernelSU 在 late_start 阶段执行本脚本）
#
# 本脚本只负责看护 bridge.sh，而且**只在有手柄连着的时候才让它跑**：
#   * 等 sys.boot_completed=1（bridge 要用 dumpsys / settings，都得等服务起来）
#   * 每 20 秒检查一次有没有"带 FF 且有 hidraw 的手柄"接入
#   * 有 → setsid 起 bridge；bridge 退出（手柄拔了 / 出错）就回到检查
#   * 没有 → 什么都不做，零开销
#   * 模块被 disable 标记停用 → 自己退出
#
# 为什么需要看护：bridge 依赖 `dumpsys input`，system_server 重启 / 手柄热插拔后
# 它的内部状态可能失效；没有看护的话手柄震动会一直失效到下次开机。

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(pwd) ;;
esac
LOG="$MODDIR/gp.log"
BRIDGE="$MODDIR/bridge.sh"
CFG="$MODDIR/config"

log() { echo "$(date '+%F %T') [service] $*" >> "$LOG"; }

cfg_on() { case "$1" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
cfg_raw() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -1; }
enabled() {
    [ -e "$MODDIR/disable" ] && return 1
    [ -e "$MODDIR/disable-gamerumble" ] && return 1
    cfg_on "$(cfg_raw FIX_GAMEPAD_RUMBLE)"
}

# ⚠️ 杀 bridge 必须杀**整个进程组**，不能只杀主壳。
# bridge 是 `setsid` 起的（自成会话/进程组，PGID == 主壳 PID），它的子进程有
# logcat（阻塞在 socket 上）和那个跑 while read 循环的子壳。只 `kill -9 <主壳>`
# 的话这两个会活下来继续转发 —— 实测出现过新旧两份同时工作（手柄收到两份报告）。
kill_bridge_tree() {
    p="$1"
    [ -n "$p" ] || return 0
    [ -d "/proc/$p" ] || return 0
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "bridge.sh" || return 0
    # 负号 = 整个进程组。⚠️ 只有 $p **自己就是组长**（PGID == PID）时才敢这么杀 ——
    # 否则 `kill -9 -$p` 会把 PGID 恰好等于 $p 的那个**无关进程组**一起干掉。
    # bridge 是 setsid 起的，正常情况它就是组长；这里只是加一道保险。
    if [ "$(awk '{print $5}' "/proc/$p/stat" 2>/dev/null)" = "$p" ]; then
        kill -9 "-$p" 2>/dev/null
    fi
    kill -9 "$p" 2>/dev/null
    # 兜底：把残留的 bridge 进程再扫一遍（进程组号万一不是 PID）。
    # ⚠️ 用一次 `ps` 拿候选，别写成"对每个 pid fork tr+grep" —— 那种写法在 Android 上
    # 实测要 **7 秒**（一千多个进程 × 两个 fork），而这几秒里新起来的 bridge 会被
    # 下面的清理误伤（真踩过）。
    for k in $(ps -A -o PID,ARGS 2>/dev/null | grep "bridge.sh" | awk '{print $1}'); do
        [ "$k" = "$$" ] && continue
        _c=$(tr '\0' ' ' < "/proc/$k/cmdline" 2>/dev/null)
        # 只杀"守护进程"形态的调用；带这些参数的是 WebUI/命令行的一次性调用，别误杀
        case "$_c" in
            *--set*|*--apply*|*--json*|*--discover*|*--once*|*--status*) continue ;;
        esac
        kill -9 "$k" 2>/dev/null
    done
    sleep 1
    # ⚠️ 只有 pidfile / 锁里**还是我们刚杀掉的那个 pid** 时才清它们。
    # 原来是无条件 `rm -f "$PIDFILE"`，结果：读 pidfile(旧 pid) → 杀 → 慢扫 7 秒 →
    # rm —— 这 7 秒里新一代 bridge 已经起来并写好了自己的 pidfile，被这一 rm 删掉，
    # 看护于是以为 bridge 退了、每 25 秒重启一次，每次又被锁挡住 → 无限循环。
    _cur=""
    [ -f "$PIDFILE" ] && read -r _cur < "$PIDFILE" 2>/dev/null
    [ "$_cur" = "$p" ] && rm -f "$PIDFILE"
    _cur=""
    [ -f "$LOCK/pid" ] && read -r _cur < "$LOCK/pid" 2>/dev/null
    [ "$_cur" = "$p" ] && rm -rf "$LOCK" 2>/dev/null
    return 0
}

# bridge 还活着吗？活着就把 pid 打出来。
#
# 判据看**两个**来源：bridge.pid（bridge 自己写的）和 .bridge.lock/pid（单实例锁的
# 持有者）。为什么不能只看 bridge.pid：它只是个便利文件，任何一次清理都可能把它和
# 实际状态搞不同步 —— 实测就是这么进入"看护每 25 秒重启一次、每次被锁挡住"的死循环，
# 而 WebUI 同时显示"未运行"。
#
# ⚠️ 这个函数在 5 秒循环里跑，只用 shell 内建，一次 fork 都不许有（read 是内建）。
bridge_pid() {
    local _f _p=""
    for _f in "$PIDFILE" "$LOCK/pid"; do
        [ -f "$_f" ] || continue
        read -r _p < "$_f" 2>/dev/null
        [ -n "$_p" ] || continue
        [ -d "/proc/$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    return 1
}

[ -x "$BRIDGE" ] || chmod 755 "$BRIDGE" 2>/dev/null

# 看护自己的 pid（主循环一开始就写下来）。用来判断"看护在不在跑"。
# ⚠️ 不能靠扫 /proc 匹配 "service.sh" 来判断 —— `--apply` 那个一次性进程自己的
# cmdline 里也有 service.sh，会把自己误判成"看护已经在跑"。
# （uninstall.sh 早就在读这个文件了，但这边一直没写，所以那段其实是死代码。）
WATCHDOG_PID="$MODDIR/service.pid"
PIDFILE="$MODDIR/bridge.pid"
LOCK="$MODDIR/.bridge.lock"
watchdog_pid() {
    local _p
    _p=$(cat "$WATCHDOG_PID" 2>/dev/null)
    [ -n "$_p" ] || return 1
    [ -d "/proc/$_p" ] || return 1
    tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q "service.sh" || return 1
    printf '%s' "$_p"
}

# ---------------------------------------------------------------- --apply
# WebUI 改完开关后调这个，让改动**立刻生效**，不用重启设备。
#
# 为什么需要：service.sh 平时只在开机时被 KernelSU 拉起一次。如果开机那一刻开关是
# 关的，它就直接 exit 0；之后在 WebUI 把开关打开，**没有任何人会再来启动它** ——
# 表现就是"开关打开了但守护进程没起来，必须再重启一次"（实测就这么绕过一圈）。
#
# 注意：停用时**不**回滚 Settings.System.vibrate_input_devices，这是本模块一贯的
# 口径（见 uninstall.sh 末尾的说明）：它是 Android 的标准设置项，本机是被移植包留成
# 未设置；留着没有副作用，真要还原是 `settings delete system vibrate_input_devices`。
if [ "${1:-}" = "--apply" ]; then
    if enabled; then
        # ① 框架开关立刻生效（不然要等下次开机）
        if [ "$(settings get system vibrate_input_devices 2>/dev/null)" != "1" ]; then
            settings put system vibrate_input_devices 1 2>/dev/null \
                && log "[apply] 已启用：vibrate_input_devices 已即时设为 1" \
                || log "[apply] WARN 写 vibrate_input_devices 失败"
        else
            log "[apply] 已启用：vibrate_input_devices 已是 1"
        fi
        # ② 看护在跑吗？不在就起一个（它自己会在几秒内发现手柄并起 bridge）
        if _wp=$(watchdog_pid); then
            log "[apply] 看护已在跑（pid=$_wp），等它下一轮发现手柄"
        else
            log "[apply] 启动看护"
            setsid /system/bin/sh "$MODDIR/service.sh" --webui >/dev/null 2>&1 </dev/null &
        fi
    else
        # 顺序要紧：**先停看护、再停 bridge**。反过来的话看护可能在中间又起一个
        # bridge，结果就是我们刚杀掉、它又拉起来一个。
        if _wp=$(watchdog_pid); then
            kill -9 "$_wp" 2>/dev/null
            log "[apply] 已关闭：看护已停（pid=$_wp）"
        fi
        rm -f "$WATCHDOG_PID"
        # kill_bridge_tree 自己会在确认死透之后清掉 pidfile / 锁（且只清"是它自己"的
        # 那一份），所以这里**不要**再补一句无条件 rm —— 那正是死循环的起因。
        kill_bridge_tree "$(bridge_pid)"
        log "[apply] 已关闭：bridge 已停（框架开关按惯例保留不动）"
    fi
    exit 0
fi

if ! enabled; then
    log "本模块已被关闭（config / disable 标记），不启动 bridge"
    exit 0
fi

# 从这一刻起算"看护在跑"（--apply 靠这个文件判断，别等到主循环里才写）
echo $$ > "$WATCHDOG_PID"

# 等系统服务起来
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 300 ]; do
    sleep 2
    i=$((i + 1))
done
sleep 5

# 日志轮转：超过 256KB 就挪走一份
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 262144 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

case "${1:-}" in
    --webui) log "--- 看护启动（由 WebUI 开关触发）---" ;;
    *)       log "--- 开机动作开始（$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)）---" ;;
esac

# 开机就把开关设上，**不等手柄接入** —— 否则"没手柄时守护进程不启动"会让这个设置
# 一直不生效（用户先插手柄之前 `settings get` 一直是 null）。
# bridge.sh 启动时也会查一遍（幂等），这里只是让状态尽早正确。
if [ "$(settings get system vibrate_input_devices 2>/dev/null)" != "1" ]; then
    settings put system vibrate_input_devices 1 2>/dev/null \
        && log "vibrate_input_devices 已设为 1（手柄震动开关）" \
        || log "WARN 写 vibrate_input_devices 失败"
else
    log "vibrate_input_devices 已是 1"
fi

# 清掉上一代残留的 bridge（KernelSU 不会自动回收 setsid 出来的进程）
# ⚠️ 必须用 kill_bridge_tree（杀**整个进程组**），不能只 `kill -9` 主壳 ——
# bridge 是 setsid 起的，子进程有 logcat（阻塞在 socket 上）和跑 while read 循环的子壳；
# 只杀主壳它们会活下来继续转发，于是新旧两份同时工作（手柄收到两份报告）。实测踩过。
# （kill_bridge_tree 会在确认死透之后自己清掉 pidfile / 锁，这里不用再 rm）
kill_bridge_tree "$(bridge_pid)"

CHECK_SECS=$(cfg_raw CHECK_SECONDS); case "$CHECK_SECS" in ''|*[!0-9]*) CHECK_SECS=20 ;; esac
[ "$CHECK_SECS" -lt 5 ] && CHECK_SECS=5
HB="$MODDIR/.heartbeat"

# 两种模式：
#   logcat（默认）—— 事件驱动，阻塞在 socket 上几乎不耗 CPU（实测 ~0.1% 单核），零延迟。
#                    但 logd 对每个缓冲区有并发读者上限，读者一多会**静默订阅不上**。
#   poll（兜底）  —— 轮询 `dumpsys input`，约 7% 单核，但不受读者上限影响、也不依赖
#                    内核的 DEBUG_VIBRATOR 编译开关。
# 判据：logcat 模式下 bridge 每收到一行日志就更新一次心跳文件（订阅了 DisplayManager /
# SurfaceFlinger / PowerManagerService / BatteryService 这组**低频**探针，合计约 10 行/秒，
# 所以正常时心跳一直很新）。心跳超过 HB_TIMEOUT 秒没动 = 订阅死了 → 切轮询。
# ⚠️ 这个超时不能太短。实测踩到：屏幕熄屏后 DisplayManager / SurfaceFlinger /
# PowerManagerService / BatteryService 全都会安静下来，60 秒就误判成"订阅死了"
# 切到轮询。放到 300 秒能避开绝大多数熄屏场景；就算真误判了，代价也只是多耗点电
# （轮询模式仍然能工作），不会丢功能。
HB_TIMEOUT=300
force_poll=0
last_pads=""

while :; do
    if ! enabled; then
        log "被关闭，看护退出"
        break
    fi

    # 有没有手柄？bridge.sh --discover 会打印 "deviceId /dev/hidrawN"，空就是没有
    pads=$(sh "$BRIDGE" --discover 2>/dev/null)
    if [ -z "$pads" ]; then
        # 没手柄：退出前把模式偏好复位，下次接入重新从 logcat 试起
        [ -n "$last_pads" ] && log "手柄已断开"
        last_pads=""
        force_poll=0
        sleep "$CHECK_SECS"
        continue
    fi
    [ "$pads" != "$last_pads" ] && log "发现手柄：$(echo "$pads" | tr '\n' ' ')"
    last_pads="$pads"

    # 清掉上一代的心跳，否则 service.sh 会拿着旧时间戳误判"订阅还活着"
    rm -f "$HB"
    if [ "$force_poll" = "1" ]; then
        log "以轮询模式启动 bridge（logcat 订阅不可用时的兜底）"
        setsid /system/bin/sh "$BRIDGE" --poll >/dev/null 2>&1 </dev/null &
    else
        log "以 logcat 模式启动 bridge（事件驱动）"
        setsid /system/bin/sh "$BRIDGE" >/dev/null 2>&1 </dev/null &
    fi

    # 看护：每 5 秒看一次进程是否还在、心跳是否还新鲜
    n=0
    while :; do
        sleep 5
        n=$((n + 1))
        enabled || break
        bridge_pid >/dev/null || break              # bridge 自己退了（看 pidfile 和锁）
        [ "$n" -ge 4320 ] && { log "bridge 已运行 6 小时，强制轮换"; break; }

        if [ "$force_poll" != "1" ]; then
            hb=$(cat "$HB" 2>/dev/null)
            read -r _u _ < /proc/uptime
            now=${_u%.*}
            case "$hb" in
                ''|*[!0-9]*) ;;                     # 还没写出心跳，再等等
                *) if [ $((now - hb)) -gt "$HB_TIMEOUT" ]; then
                       log "logcat 心跳已停 $((now - hb))s（订阅被 logd 拒了），改用轮询模式"
                       force_poll=1
                       kill_bridge_tree "$(bridge_pid)"
                       break
                   fi ;;
            esac
        fi
    done

    enabled || { log "被关闭，看护退出"; break; }
    sleep "$CHECK_SECS"
done

rm -f "$WATCHDOG_PID"
log "--- 看护结束 ---"
