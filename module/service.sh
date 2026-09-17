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
    kill -9 "-$p" 2>/dev/null      # 负号 = 整个进程组
    kill -9 "$p" 2>/dev/null
    # 兜底：按 cmdline 再扫一遍（进程组号万一不是 PID）
    for k in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        tr '\0' ' ' < "/proc/$k/cmdline" 2>/dev/null | grep -q "bridge.sh" || continue
        kill -9 "$k" 2>/dev/null
    done
    sleep 1
}

[ -x "$BRIDGE" ] || chmod 755 "$BRIDGE" 2>/dev/null

if ! enabled; then
    log "本模块已被关闭（config / disable 标记），不启动 bridge"
    exit 0
fi

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

log "--- 开机动作开始（$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)）---"

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
if [ -f "$MODDIR/bridge.pid" ]; then
    old=$(cat "$MODDIR/bridge.pid" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ] && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "bridge.sh"; then
        kill -9 "$old" 2>/dev/null
        log "已清掉上一代 bridge pid=$old"
    fi
    rm -f "$MODDIR/bridge.pid"
fi

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
        [ -f "$MODDIR/bridge.pid" ] || break        # bridge 自己退了
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
                       kill_bridge_tree "$(cat "$MODDIR/bridge.pid" 2>/dev/null)"
                       break
                   fi ;;
            esac
        fi
    done

    enabled || { log "被关闭，看护退出"; break; }
    sleep "$CHECK_SECS"
done

log "--- 看护结束 ---"
