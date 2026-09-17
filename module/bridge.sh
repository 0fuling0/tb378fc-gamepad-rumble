#!/system/bin/sh
# TB378FC 手柄震动修复 —— 守护进程
#
# 这个脚本是干什么的
# ==================
# 本机内核的 hid-microsoft 驱动给 Xbox Series 手柄（045e:0b13）构造 FF 输出报告时，
# 结构体字段顺序和手柄自己 HID 描述符声明的顺序不一致：
#
#   struct xb1s_ff_report {   /* 驱动，sizeof = 9 */
#       u8 report_id;         /* 3 */
#       u8 enable;            /* 0x03 */
#       u8 magnitude[4];      /* [2]=strong(左马达) [3]=weak(右马达) */
#       u8 duration_10ms;     /* 0xFF */
#       u8 start_delay_10ms;  /* 0x00 */
#       u8 loop_count;        /* 0xFF */
#   };
#
# 而手柄描述符声明的是 [Duration][Loop Count][Start Delay] —— 后两个字节相反。
# 于是控制器把驱动发的 `... FF 00 FF` 读成「loop=0、delay=0xFF（2.55 秒延迟）」，
# **永远震不起来**。实测对照（同样的幅值，只换这两个字节的顺序）：
#
#   03 03 00 00 ff ff ff 00 ff   ← 驱动顺序      → 不震
#   03 0f 00 00 ff ff ff ff 00   → 描述符顺序    → 震 ✓
#
# 驱动是内建的、框架侧 EventHub 是 native，两边都改不了。所以这里换个思路：
# **不去改内核，而是"抄一遍"框架的震动意图，自己发一份格式正确的报告。**
#
# 怎么知道框架什么时候要震
# ========================
# 本机内核的 InputReader 编译时打开了 DEBUG_VIBRATOR，每次下发震动都会打日志：
#
#   D InputReader: nextStep: sending vibrate deviceId=11, element=[duration=1000ms, channels=[0 : 255, 1 : 255]]
#   D InputReader: stopVibrating: sending cancel vibrate deviceId=11
#
# 这一行里已经有全部需要的信息（设备号 / 时长 / 两个马达的幅值）。所以只要
# `logcat -s InputReader` 跟着日志走，就能**推送式**地拿到震动请求，不需要轮询。
#
# 怎么把 deviceId 对应到手柄的 hidraw
# ==================================
# 日志里的 deviceId 是 **InputReader 的编号**（和 `dumpsys input` 里
# `Input Devices:` 段的 InputManagerService 编号**不是同一套**，别搞混）。
# InputReader 段每个设备都带 `SysfsRootPath`，而 uhid 设备目录下有 hidraw：
#
#   Device 11: Xbox Wireless Controller
#     SysfsRootPath:     /sys/devices/virtual/misc/uhid/0005:045E:0B13.0001
#       └── hidraw/hidraw0
#
# 所以一次 `dumpsys input` 就能建出「deviceId → /dev/hidrawN」的映射。

# ⚠️ 不能只写 MODDIR=${0%/*} —— 用 `sh bridge.sh` 这样不带路径地调用时，
# $0 里没有斜杠，${0%/*} 会原样返回 "bridge.sh"，后面所有路径就全错了。
case "$0" in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(pwd) ;;
esac
LOG="$MODDIR/gp.log"
HID_MAP="$MODDIR/.hidmap"          # deviceId -> /dev/hidrawN（由 discover 生成）
STATE="$MODDIR/.state"             # 每次轮询解析出来的设备状态（临时文件）
PIDFILE="$MODDIR/bridge.pid"
LOCK="$MODDIR/.bridge.lock"          # 单实例锁（mkdir 原子）
HB="$MODDIR/.heartbeat"              # 心跳（service.sh 靠它判断 logcat 订阅是否还活着）
CFG="$MODDIR/config"
VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

cfg_on() { case "$1" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
# ⚠️ 不要用 `sed -n "s/^$1=//p"` 实现这个函数 —— 主循环每轮都会调它（判断开关状态），
# 每轮 spawn 一个 sed 就是 2~5ms CPU，实测占了守护进程静止开销的一大半。
# 用 shell 内建 read + 参数展开，一次 fork 都没有。
cfg_raw() {
    local _line _v=""
    if [ -f "$CFG" ]; then
        while IFS= read -r _line; do
            case "$_line" in
                "$1="*) _v="${_line#*=}" ;;
            esac
        done < "$CFG"
    fi
    printf '%s' "$_v"
}
enabled() {
    [ -e "$MODDIR/disable" ] && return 1
    [ -e "$MODDIR/disable-gamerumble" ] && return 1
    cfg_on "$(cfg_raw FIX_GAMEPAD_RUMBLE)"
}

# 存在的 disable-* 标记文件，给 WebUI 用（提示"开关被标记文件盖掉了"）。
# 标记的优先级高于 config —— enabled() 里就是先查标记、再查 config。
markers_list() {
    local _m _out=""
    for _m in disable disable-gamerumble; do
        [ -e "$MODDIR/$_m" ] && _out="$_out $_m"
    done
    printf '%s' "$_out"
}

# ---------------------------------------------------------------- 报告构造
# 按**手柄描述符声明的顺序**拼 9 字节输出报告（report ID 3）：
#   [0]=0x03 [1]=使能 0x0F [2..5]=4 个幅值（[2]/[3] 是左/右马达）
#   [6]=持续时间(×10ms) [7]=循环次数 [8]=起始延迟(×10ms)
#
# ⚠️ 不能用 `$(...)` 拼二进制 —— shell 的命令替换会把 NUL 字节吃掉。
# 所以固定部分写成 printf 的转义、只有动态的 3 个字节用 %b 展开：
#   $(printf '\\%03o' N) 得到的是**文本** "\310"（反斜杠 + 三个数字），没有 NUL，
#   再交给 printf 的 %b 去解释成字节。这样才安全。
oct() { printf '\\%03o' "$1"; }

send_report() {
    # $1 = hidraw 节点  $2 = 左马达  $3 = 右马达  $4 = duration(×10ms)  $5 = loop
    printf '\003\017\000\000%b%b%b%b\000' \
        "$(oct "$2")" "$(oct "$3")" "$(oct "$4")" "$(oct "$5")" > "$1" 2>/dev/null
}

send_stop() {
    # 幅值全 0、时长最短 —— 让马达立刻停
    printf '\003\017\000\000\000\000\001\001\000' > "$1" 2>/dev/null
}

# ---------------------------------------------------------------- 设备发现
# 输出 deviceId -> /dev/hidrawN，只保留「有 Vibrator Input Mapper（= 内核给了 FF）
# 且 SysfsRootPath 下有 hidraw 节点」的设备 —— 也就是真正的手柄。
# qcom-hv-haptics 这类设备也有 Vibrator Input Mapper，但没有 hidraw，会被自动跳过。
discover() {
    # awk 里没法直接 ls，所以分两步：先拿 (deviceId, SysfsRootPath)，再用 shell 解析 hidraw
    #
    # ---- 判据（只认"确实是手柄"的设备）----
    #   1) `SysfsRootPath` 存在                       —— 拿到 uhid 设备目录
    #   2) 该目录下有 hidraw 节点                     —— 有输出报告的通道（能真的发出去）
    #   3) `Sources:` 里含 `GAMEPAD` 或 `JOYSTICK`    —— **确实是手柄**
    #
    # 第 3 条是必须的：光靠 1)+2) 的话，接个蓝牙键盘 / 鼠标 / 自拍杆也会被当成目标，
    # 而它们收到那 9 字节的"手柄 rumble 报告"只会莫名其妙。
    # 两个都接受是因为有些手柄只报 JOYSTICK 不报 GAMEPAD（实测造了个只报 JOYSTICK 的
    # 假设备验证过），漏掉它会少识别一部分手柄；而键盘/鼠标/触摸/笔都不会报这两个，
    # 所以放宽到"GAMEPAD 或 JOYSTICK"不会误伤。
    # 本机实测各设备的 Sources：
    #     Xbox Wireless Controller   KEYBOARD | GAMEPAD | JOYSTICK   ← 唯一命中
    #     qcom-hv-haptics            KEYBOARD                        （平板触感，无 hidraw）
    #     NVTCapacitiveTouchScreen   KEYBOARD | TOUCHSCREEN          （无 hidraw）
    #     NVTCapacitivePen           KEYBOARD | TOUCHSCREEN | STYLUS （无 hidraw）
    #     pmic_resin / pmic_pwrkey / gpio-keys   KEYBOARD             （无 hidraw）
    # 顺带说明：平板**根本没有震动马达**，qcom-hv-haptics 只是 SoC 里那个触感控制器；
    # 它没有 hidraw，所以本来就不会被映射 —— 这里再用 GAMEPAD 兜一层。
    #
    # ⚠️ 判据里**不要**加 `Vibrator Input Mapper`。实测踩到过：蓝牙重连之后 InputReader
    # 有时不会给手柄重建 VibratorInputMapper（内核侧 FF 还在，/proc/bus/input/devices 的
    # B: FF= 照旧、getevent -pl 也照旧），那时 dumpsys 里就没有这一段 —— 加了会直接
    # 找不到手柄。而它本来也不必要：GAMEPAD + hidraw 已经足够精确。
    # ⚠️ 临时文件名带 $$：discover 会被**并发**调用（看护每 20 秒、WebUI 的 --json /
    # --status、bridge 本体），共用一个固定名字会互相覆盖。
    tmp="$MODDIR/.devs.$$"
    dumpsys input 2>/dev/null | awk '
        /^  Device [0-9]+: / {
            if (dev != "" && root != "" && ispad) print dev " " root;
            dev = $2; sub(":", "", dev); root = ""; ispad = 0;
            next;
        }
        /SysfsRootPath:/ { root = $2; next }
        /^    Sources: /  { if ($0 ~ /GAMEPAD|JOYSTICK/) ispad = 1; next }
    END { if (dev != "" && root != "" && ispad) print dev " " root }
    ' > "$tmp" 2>/dev/null

    # ⚠️ 写临时文件再 `mv` 原子替换，**不要** `: > "$HID_MAP"` 之后逐行 append ——
    # discover 会被并发调用，两个实例会各自截断、各自 append，结果映射里出现重复条目
    # （实测见过 PAD_COUNT=2、同一行出现两次，WebUI 就显示"识别到的手柄：2 个"）。
    # 用 mv 之后，读的人要么看到旧的、要么看到新的，不会看到半成品。
    out="$MODDIR/.hidmap.$$"
    : > "$out"
    while read -r id root; do
        [ -n "$id" ] && [ -n "$root" ] || continue
        # ⚠️ 不能用 `ls "$root"/hidraw/hidraw*` —— hidraw0 是个**目录**，
        # `ls <目录>` 会列出它的内容（dev / device / power / ...），于是拿到的是
        # "dev" 这种垃圾值。这里直接用 glob + -e 判断，既拿到目录名本身，
        # 又天然处理"没有匹配"（glob 保持字面量，-e 失败）。
        node=""
        for x in "$root"/hidraw/hidraw*; do
            [ -e "$x" ] || continue
            node="/dev/$(basename "$x")"
            break
        done
        [ -n "$node" ] || continue
        [ -c "$node" ] || continue
        # 到这里 = 有 SysfsRootPath + 有 hidraw + Sources 含 GAMEPAD，才认定是手柄
        printf '%s %s\n' "$id" "$node" >> "$out"
    done < "$tmp"
    rm -f "$tmp"
    mv -f "$out" "$HID_MAP"
    return 0
}

hidraw_of() {
    [ -f "$HID_MAP" ] || return 1
    awk -v id="$1" '$1 == id { print $2; exit }' "$HID_MAP"
}

# ---------------------------------------------------------------- 主循环
#
# 触发方式：**轮询 `dumpsys input`**，不读日志。
#
# 为什么不用 logcat：这台机器的内核编译时开了 DEBUG_VIBRATOR，InputReader 每次下发震动都会打
# 一行日志，理论上 `logcat -s InputReader` 跟着走最省资源。但实测有两个硬伤：
#   1) **logd 对每个缓冲区有并发读者上限**。系统里只要已经有几个 logcat 读者
#      （KernelSU 管理器、日志 App、别的模块……），新的读者会**静默订阅不上** ——
#      进程在跑、socket 也建了，就是一行都收不到。排查时被这个坑了很久。
#   2) 依赖 `DEBUG_VIBRATOR`，那是**编译期**常量，换内核/换 ROM 可能就没了。
#
# 而 `dumpsys input` 一次调用就能同时给出：
#   * deviceId -> SysfsRootPath（-> hidraw 节点）的映射
#   * `Vibrator Input Mapper:` 下的 `Vibrating: true/false`
#   * `Pattern: [[duration=1000ms, channels=[0 : 255, 1 : 255]]]` —— 时长和两个马达的幅值
# 实测一次约 12~19ms，轮询代价可接受，而且**没有读者上限问题**。
#
# 轮询节奏：静止时慢（省电），一旦有手柄在震就快（跟上游戏）。
# ---------------------------------------------------------------- 单实例锁
# **必须有**。实测漏了一个旧进程时，两个 bridge 会同时转发，手柄收到两份报告
# （日志里每件事都成对出现）。service.sh 虽然会按 pidfile 清理，但 pidfile 可能
# 过期/丢失，所以这里用 mkdir 原子锁兜底。
acquire_lock() {
    if ! mkdir "$LOCK" 2>/dev/null; then
        old=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$old" ] && [ -d "/proc/$old" ] \
                && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "bridge.sh"; then
            log "已有 bridge 在跑 (pid=$old)，本实例退出"
            return 1
        fi
        # 锁是陈的（持有者已死）→ 接管
        rm -rf "$LOCK" 2>/dev/null
        mkdir "$LOCK" 2>/dev/null || { log "抢锁失败，退出"; return 1; }
    fi
    echo $$ > "$LOCK/pid"
    echo $$ > "$PIDFILE"
    return 0
}

# ---------------------------------------------------------------- 心跳
# logcat 模式下每收到一行就更新一次（限流到 1 秒一次）。
# service.sh 靠它判断"订阅是否还活着"：订阅被 logd 拒掉时是**完全静默**的
# （进程在、socket 也在，就是一行都收不到），光看进程存在发现不了。
touch_hb() {
    read -r _u _ < /proc/uptime
    _t=${_u%.*}
    if [ $((_t - hb_t)) -ge 1 ]; then
        echo "$_t" > "$HB"
        hb_t=$_t
    fi
}

# ---------------------------------------------------------------- logcat 模式（默认）
#
# 为什么默认用这个：logcat 是**原生二进制**，阻塞在 socket 上等日志时几乎不耗 CPU
# （实测 20 秒只用了 1 jiffies，约 0.1% 单核），而且事件驱动 —— 框架一下发震动就立刻
# 拿到，零延迟。相比之下轮询 `dumpsys input` 要 7% 单核（dumpsys 是 Java 程序）。
#
# 代价：logd 对每个缓冲区有**并发读者上限**，系统里读者一多，新读者会静默订阅不上。
# 所以 service.sh 会用心跳文件盯着；一旦发现订阅死了就改用轮询模式（见 run_poll）。
run_logcat() {
    acquire_lock || exit 0
    log "bridge 启动 pid=$$ 模式=logcat（事件驱动）"

    if [ "$(settings get system vibrate_input_devices 2>/dev/null)" != "1" ]; then
        settings put system vibrate_input_devices 1 2>/dev/null \
            && log "vibrate_input_devices 已设为 1"
    fi

    discover
    log "初始映射: $(tr '\n' ' ' < "$HID_MAP" 2>/dev/null)"
    hb_t=0
    touch_hb
    # 上一次真正发过震动报告的 deviceId —— 只有它才需要收停止报告。
    # 为什么需要：框架会给**空模式**（pattern=[[]]，比如键盘的预置触感）也发一次
    # cancel vibrate，那不是"刚才在震、现在停了"，只是它转不成手柄波形而已。
    # 不加这个判断会白发一堆停止报告（实测日志里全是无意义的"停止"）。
    rumbling_id=""
    RESCAN=$(cfg_raw RESCAN_SECONDS); case "$RESCAN" in ''|*[!0-9]*) RESCAN=10 ;; esac
    read -r _u _ < /proc/uptime
    last_disc=${_u%.*}

    # 同时订阅 ActivityManager 当"存活探针"：
    #   InputReader 只在真的震动时才打日志，光靠它无法区分"这段时间没震动"和
    #   "订阅根本是死的"。ActivityManager 一直有输出，它一停就说明订阅断了。
    # 探针标签：InputReader 只在真震动时才有日志，光靠它无法区分"这段时间没震动"
    # 和"订阅根本是死的"，所以要搭几个**一直在说话**的标签当活体探针。
    #
    # ⚠️ 探针要挑**低频**的。实测各标签的行速率：
    #     ActivityManager      640 行/秒   ← 一开始用的这个，代价最大
    #     WindowManager        333
    #     AlarmManager         123
    #     DisplayManager       4.0
    #     SurfaceFlinger       3.7
    #     PowerManagerService  2.0
    #     BatteryService       0.7
    # 用 ActivityManager 时，logcat 要往管道写 640 行/秒、循环跟着醒 640 次/秒 ——
    # 实测 500 秒里 logcat 吃了 500ms CPU（0.1% 单核）、循环子壳 170ms。
    # 而单独跑 `logcat -s InputReader` 15 秒是 **0ms** —— 说明 logcat 自己的格式化
    # 开销可忽略，成本全在"写管道 + 循环读"的 IPC/上下文切换上。
    # 换成下面这组合计约 10 行/秒，比原来少 64 倍。
    #
    # 另一个试过但**不可行**的判据：读 logcat 的 /proc/<pid>/io 的 rchar。
    # 实测它不增长 —— logcat 是用 recvmsg() 读 netlink socket，不经过 vfs_read，
    # 所以 rchar/syscr 都不计 socket 读取。
    #
    # ⚠️ `-T 1` 不能省：不加的话 logcat 会把缓冲区里的**历史日志**先倒一遍，
    # 于是启动瞬间会把过去那些震动记录全部重发一次（实测同一秒内发了 10 条）。
    # `-T N` 的语义是"从最近 N 行开始跟"（且不隐含 -d，仍然持续跟随），
    # 所以 -T 1 = 跳过积压、只跟新日志。
    logcat -b all -v brief -T 1 -s InputReader DisplayManager SurfaceFlinger \
        PowerManagerService BatteryService 2>/dev/null | \
    while IFS= read -r line; do
        [ -e "$MODDIR/disable" ] && break
        touch_hb

        # 每 RESCAN 秒刷新一次 deviceId -> hidraw（手柄插拔后编号会变）
        read -r _u _ < /proc/uptime
        now=${_u%.*}
        if [ $((now - last_disc)) -ge "$RESCAN" ]; then
            discover
            last_disc=$now
        fi

        case "$line" in
            *"nextStep: sending vibrate deviceId="*)
                id="${line##*deviceId=}"; id="${id%%,*}"
                case "$id" in ''|*[!0-9]*) continue ;; esac
                node=$(hidraw_of "$id")
                [ -n "$node" ] || continue

                dur="${line##*duration=}"; dur="${dur%%ms*}"
                case "$dur" in ''|*[!0-9]*) dur=0 ;; esac
                # 先按逗号切（两通道 "255, 1 : 255"），再剥掉尾部的 ']'
                # （单通道时是 "128]]" —— 少剥这一步会整段被判成非数字 → 幅值变 0）
                l="${line##*channels=[0 : }"; l="${l%%,*}"; l="${l%%]*}"
                case "$l" in ''|*[!0-9]*) l=0 ;; esac
                r="${line##*1 : }"; r="${r%%]*}"
                case "$r" in ''|*[!0-9]*) r=0 ;; esac

                if [ "$l" = "0" ] && [ "$r" = "0" ]; then
                    send_stop "$node"
                    continue
                fi
                d10=$((dur / 10)); [ "$d10" -lt 1 ] && d10=1; [ "$d10" -gt 255 ] && d10=255
                loop=$(( (dur / 10 + 254) / 255 )); [ "$loop" -lt 1 ] && loop=1; [ "$loop" -gt 8 ] && loop=8
                send_report "$node" "$l" "$r" "$d10" "$loop"
                rumbling_id="$id"
                log "转发 -> deviceId=$id $node 左=$l 右=$r 时长=${dur}ms 循环=$loop"
                ;;

            *"stopVibrating: sending cancel vibrate deviceId="*|*"nextStep: sending cancel vibrate deviceId="*)
                id="${line##*deviceId=}"; id="${id%%,*}"
                case "$id" in ''|*[!0-9]*) continue ;; esac
                [ "$id" = "$rumbling_id" ] || continue     # 没发过震动，不需要停止
                node=$(hidraw_of "$id")
                [ -n "$node" ] || continue
                send_stop "$node"
                rumbling_id=""
                log "停止 -> deviceId=$id $node"
                ;;
        esac
    done

    log "bridge 退出（logcat 模式）"
    rm -f "$PIDFILE"
    rm -rf "$LOCK" 2>/dev/null
    exit 0
}

# ---------------------------------------------------------------- 轮询模式（兜底）
run_poll() {
    acquire_lock || exit 0
    log "bridge 启动 pid=$$ 模式=轮询（兜底）"

    # 框架层面必须先能把手柄震动下发下来，否则 Vibrator Input Mapper 永远不会 true
    if [ "$(settings get system vibrate_input_devices 2>/dev/null)" != "1" ]; then
        settings put system vibrate_input_devices 1 2>/dev/null \
            && log "vibrate_input_devices 已设为 1"
    fi

    IDLE_MS=$(cfg_raw IDLE_POLL_MS);   case "$IDLE_MS" in ''|*[!0-9]*) IDLE_MS=500 ;; esac
    REFRESH_MS=$(cfg_raw REFRESH_MS);  case "$REFRESH_MS" in ''|*[!0-9]*) REFRESH_MS=5000 ;; esac
    EXIT_NOPAD=$(cfg_raw EXIT_WHEN_NO_PAD)
    case "$EXIT_NOPAD" in 0|false|no|off) EXIT_NOPAD=0 ;; *) EXIT_NOPAD=1 ;; esac
    ACTIVE_MS=$(cfg_raw ACTIVE_POLL_MS); case "$ACTIVE_MS" in ''|*[!0-9]*) ACTIVE_MS=120 ;; esac
    [ "$IDLE_MS" -lt 100 ] && IDLE_MS=100
    [ "$ACTIVE_MS" -lt 50 ] && ACTIVE_MS=50

    # 每个设备记住上一轮的状态，用于去重：只有状态真的变了才重发
    # 形如 "11|1|255|255;"，前一次为空
    prev_all=""
    last_send_all=""
    last_map_log=""
    node_cache=""      # " 11=/dev/hidraw0 5=/dev/hidraw1"（只在缓存未命中时才做目录 glob）

    # ⚠️ 性能要点：这个循环每 120~500ms 跑一次，**绝不能在里面 spawn 进程**。
    # 实测每 spawn 一个（date / basename / grep / tr / cut）约 2~5ms CPU，
    # 一轮里好几个就攒到 ~70ms —— 相比 dumpsys 本身的 5ms，开销几乎全在这里。
    # 所以下面全部用 shell 内建：${x##*/} 代替 basename、读 /proc/uptime 代替 date、
    # case 参数展开代替 grep/tr/cut，sleep 的秒数字符串在循环外预先算好。
    read -r _up _ < /proc/uptime
    now=${_up%.*}
    IDLE_SLEEP="$((IDLE_MS / 1000)).$(printf '%03d' $((IDLE_MS % 1000)))"
    ACTIVE_SLEEP="$((ACTIVE_MS / 1000)).$(printf '%03d' $((ACTIVE_MS % 1000)))"
    log "轮询间隔: 静止 ${IDLE_MS}ms / 震动中 ${ACTIVE_MS}ms"

    while :; do
        [ -e "$MODDIR/disable" ] && { log "发现 disable 标记，退出"; break; }
        enabled || { log "本模块已关闭，退出"; break; }

        # 一次 dumpsys 拿到全部信息：dev root vib dur l r
        # （解析逻辑在 parse-input.awk 里 —— 抽成独立文件，既方便单独测，
        #   也不会被 tools/check-helpers.py 误当成 shell 代码解析）
        dumpsys input 2>/dev/null | awk -f "$MODDIR/parse-input.awk" > "$STATE" 2>/dev/null

        read -r _up _ < /proc/uptime
        now=${_up%.*}
        # 同 discover()：写临时文件、循环结束后原子 mv（避免和并发的 --json / 看护
        # 的 discover 互相踩出重复条目）
        out="$MODDIR/.hidmap.$$"
        : > "$out"
        new_all=""
        send_all=""
        any_active=0
        map_txt=""

        while read -r id root vib dur l r; do
            [ -n "$id" ] && [ -n "$root" ] || continue

            # deviceId -> hidraw 节点（缓存；未命中才 glob）
            # ⚠️ 不能用 `ls "$root"/hidraw/hidraw*` —— hidraw0 是**目录**，
            # `ls <目录>` 会列出它的内容（dev/device/power/...），拿到的是垃圾值。
            case "$node_cache" in
                *" $id="*) rest="${node_cache#*" $id="}"; node="${rest%% *}" ;;
                *)         node="" ;;
            esac
            if [ -z "$node" ]; then
                for x in "$root"/hidraw/hidraw*; do
                    [ -e "$x" ] || continue
                    node="/dev/${x##*/}"
                    break
                done
                [ -n "$node" ] && [ -c "$node" ] && node_cache="$node_cache $id=$node"
            fi
            [ -n "$node" ] && [ -c "$node" ] || continue
            printf '%s %s\n' "$id" "$node" >> "$out"
            map_txt="$map_txt$id->$node "

            [ -n "$l" ] || l=0
            [ -n "$r" ] || r=0
            [ -n "$dur" ] || dur=0

            active=0
            if [ "$vib" = "1" ] && { [ "$l" != "0" ] || [ "$r" != "0" ]; }; then
                active=1
                any_active=1
                new_all="$new_all$id|1|$l|$r;"
            else
                new_all="$new_all$id|0|0|0;"
            fi

            # 上一轮的状态（纯参数展开，不起进程）
            pst=""
            case "$prev_all" in
                *"$id|"*) rest="${prev_all#*"$id|"}"; pst="$id|${rest%%;*}" ;;
            esac
            last_t=0
            case "$last_send_all" in
                *"$id|"*) rest="${last_send_all#*"$id|"}"; last_t="${rest%%;*}" ;;
            esac
            case "$last_t" in ''|*[!0-9]*) last_t=0 ;; esac

            if [ "$active" = "1" ]; then
                st="$id|1|$l|$r"
                # 状态没变、且距上次发送还没到 REFRESH_MS → 跳过（省 BT 流量）
                if [ "$st" = "$pst" ] && [ $(( (now - last_t) * 1000 )) -lt "$REFRESH_MS" ]; then
                    send_all="$send_all$id|$last_t;"
                    continue
                fi

                d10=$((dur / 10))
                [ "$d10" -lt 1 ] && d10=1
                [ "$d10" -gt 255 ] && d10=255
                # 循环次数：够覆盖这一拍（每轮 255×10ms），上限 8 轮 ≈ 20 秒兜底。
                # 连续震动时靠 REFRESH_MS 那个刷新续上；框架停了就发停止报告。
                loop=$(( (dur / 10 + 254) / 255 ))
                [ "$loop" -lt 1 ] && loop=1
                [ "$loop" -gt 8 ] && loop=8

                send_report "$node" "$l" "$r" "$d10" "$loop"
                send_all="$send_all$id|$now;"
                log "转发 -> deviceId=$id $node 左=$l 右=$r 时长=${dur}ms 循环=$loop"
            else
                case "$pst" in
                    "$id|1|"*)
                        send_stop "$node"
                        log "停止 -> deviceId=$id $node"
                        ;;
                esac
                send_all="$send_all$id|0;"
            fi
        done < "$STATE"
        mv -f "$out" "$HID_MAP"

        prev_all="$new_all"
        last_send_all="$send_all"

        # 没有手柄连着 → 累计空轮次数，够久就退出（service.sh 会在手柄接入时再拉起来）
        if [ -s "$HID_MAP" ]; then
            nopad=0
        else
            nopad=$(( ${nopad:-0} + 1 ))
        fi
        if [ "$EXIT_NOPAD" = "1" ] && [ "$nopad" -ge 20 ]; then
            log "连续 $nopad 轮没有找到手柄，退出（等 service.sh 再拉起）"
            break
        fi

        # 映射变化时记一条日志（手柄插拔）
        if [ "$map_txt" != "$last_map_log" ]; then
            log "设备映射: ${map_txt:-（无）}"
            last_map_log="$map_txt"
        fi

        if [ "$any_active" = "1" ]; then
            sleep "$ACTIVE_SLEEP"
        else
            sleep "$IDLE_SLEEP"
        fi
    done

    log "bridge 退出"
    rm -f "$PIDFILE"
    rm -rf "$LOCK" 2>/dev/null
    exit 0
}

case "$1" in
    --poll) run_poll ;;
    --logcat) run_logcat ;;
    --discover)
        discover; cat "$HID_MAP"; exit 0 ;;

    --set)
        # WebUI 用：sh bridge.sh --set KEY VALUE [KEY2 VALUE2 ...]
        # 只按字面替换 "KEY=" 开头的行，**不走 sed**（值里可能有 / & \ 之类会被解释的字符）。
        shift
        n=0
        while [ $# -ge 2 ]; do
            k="$1"; v="$2"; shift 2
            case "$k" in
                [A-Za-z_]*) ;;
                *) log "拒绝非法键名: $k"; continue ;;
            esac
            if grep -q "^$k=" "$CFG" 2>/dev/null; then
                awk -v k="$k" -v v="$v" '
                    index($0, k "=") == 1 { print k "=" v; next } { print }
                ' "$CFG" > "$CFG.tmp" && mv -f "$CFG.tmp" "$CFG"
            else
                printf '%s=%s\n' "$k" "$v" >> "$CFG"
            fi
            n=$((n + 1))
            log "config: $k=$v"
        done
        # 写完 config 后让改动**立刻生效**，不用重启设备。
        # service.sh 平时只在开机时被 KernelSU 拉起一次 —— 如果开机那一刻开关是关的，
        # 它早就 exit 0 了，没人会把守护进程拎起来（实测踩过：WebUI 打开开关后
        # 什么都没发生，必须再重启一次）。
        # 放在最后、且失败不中断：config 已经写进去了，重启后照样生效。
        if [ -x "$MODDIR/service.sh" ] && [ "$n" -gt 0 ]; then
            sh "$MODDIR/service.sh" --apply >/dev/null 2>&1 \
                && log "已调用 service.sh --apply（即时生效）" \
                || log "WARN service.sh --apply 失败（config 已写入，重启后仍会生效）"
        fi
        echo "已写入 $n 项，并已即时生效"
        exit 0 ;;

    --json)
        # 给 WebUI 用。注意：**不要**在这里做耗时的事（dumpsys input 约 15ms，可以接受）
        b() { if "$@" >/dev/null 2>&1; then printf 1; else printf 0; fi; }
        discover
        # 运行中？看**两个**来源：bridge.pid 和单实例锁 .bridge.lock/pid。
        # 只看 pidfile 会误报"未运行" —— 它只是个便利文件，可能被某次清理和实际状态
        # 搞不同步（实测踩过：WebUI 显示"未运行"，但手柄震动其实是好的）。
        running=0
        for _f in "$PIDFILE" "$LOCK/pid"; do
            [ -f "$_f" ] || continue
            p=$(cat "$_f" 2>/dev/null)
            [ -n "$p" ] || continue
            [ -d "/proc/$p" ] || continue
            grep -q "bridge.sh" "/proc/$p/cmdline" 2>/dev/null || continue
            running=1
            break
        done
        map=""
        if [ -s "$HID_MAP" ]; then
            map=$(tr '\n' ' ' < "$HID_MAP" | sed 's/ *$//')
        fi
        printf '{"FIX_GAMEPAD_RUMBLE":%s,"RUMBLE_SETTING":"%s","BRIDGE_RUNNING":%s,' \
            "$(b enabled)" "$(settings get system vibrate_input_devices 2>/dev/null)" "$running"
        # 注意：HID_MAP 不存在时 `wc -l < file` 输出为空，会让 JSON 变成 "PAD_COUNT":,
        # 非法 JSON → WebUI 直接报错。所以先兜底成 0。
        cnt=$(wc -l < "$HID_MAP" 2>/dev/null | tr -d ' ')
        [ -n "$cnt" ] || cnt=0
        printf '"PAD_COUNT":%s,"PAD_MAP":"%s","VERSION":"%s","MARKERS":"%s"}\n' \
            "$cnt" "$map" "$VERSION" "$(markers_list)"
        exit 0 ;;

    --status)
        echo "TB378FC 手柄震动修复  $VERSION"
        echo "模块目录: $MODDIR"
        echo
        echo "本项开关         : $(if enabled; then echo 开; else echo 关; fi)"
        echo "vibrate_input_devices : $(settings get system vibrate_input_devices 2>/dev/null)   （需要是 1）"
        if [ -f "$PIDFILE" ]; then
            p=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$p" ] && [ -d "/proc/$p" ]; then
                echo "bridge 守护进程  : 运行中 pid=$p"
            else
                echo "bridge 守护进程  : 未运行（pidfile 过期）"
            fi
        else
            echo "bridge 守护进程  : 未运行"
        fi
        discover
        pc=$(wc -l < "$HID_MAP" 2>/dev/null | tr -d ' ')
        [ -n "$pc" ] || pc=0
        echo "识别到的手柄     : $pc 个"
        if [ -s "$HID_MAP" ]; then
            while read -r id node; do
                echo "                   deviceId=$id  ->  $node"
            done < "$HID_MAP"
        else
            echo "                   （没有找到带 FF 且有 hidraw 的设备 —— 手柄没连？）"
        fi
        echo
        echo "日志: $LOG"
        exit 0 ;;

    --once)
        # 手动测一次：sh bridge.sh --once <左> <右> [时长ms]
        discover
        node=$(awk 'NR==1{print $2}' "$HID_MAP")
        [ -n "$node" ] || { echo "没有找到手柄（hidmap 为空）"; exit 1; }
        d=${4:-1000}
        send_report "$node" "${2:-255}" "${3:-255}" "$((d/10))" "$(( (d/10+254)/255 ))"
        echo "已向 $node 发送 左=${2:-255} 右=${3:-255} 时长=${d}ms"
        sleep 1
        send_stop "$node"
        exit 0 ;;

    *)
        # 默认走 logcat（便宜 + 零延迟）；service.sh 发现心跳停了会改用 --poll
        run_logcat ;;
esac
