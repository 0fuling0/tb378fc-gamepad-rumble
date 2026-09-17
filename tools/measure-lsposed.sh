#!/system/bin/sh
# 测 LSPosed 在本机的实际开销（非侵入式，不改任何配置）
#
# LSPosed 的开销分三块：
#   1. **每进程注入**：Zygisk 在 zygote fork 时把 lspd 注入到每个 App 进程 ——
#      无论那个 App 有没有被任何模块 hook。这块是"人人有份"的固定成本。
#   2. **hook 调用**：被 hook 的方法每次调用多一层跳转。
#   3. **守护进程 / 管理器**。
#
# 这里量的是 1 和 3（可以直接从 /proc 读出来）。
# 2 需要真做 A/B（禁用 LSPosed 重启对比），见脚本末尾的说明。

echo "================ 1) 哪些进程被注入了 lspd ================"
n=0
tot_pss=0
tot_rss=0
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ -r "/proc/$p/maps" ] || continue
    # lspd 的映射：路径里带 lspd / lsposed / zygisk
    hit=$(grep -m1 -oE '/[^ ]*(lspd|lsposed|zygisk)[^ ]*\.so' "/proc/$p/maps" 2>/dev/null)
    [ -n "$hit" ] || continue

    name=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    [ -n "$name" ] || name="[$(cat /proc/$p/comm 2>/dev/null)]"

    # 该进程里所有 lspd 相关映射的 Pss（smaps 里每段一行，可能有多段）
    pss=$(awk '
        /^[0-9a-f]+-[0-9a-f]+ / { cur = $0 }
        /^Pss:/ { if (cur ~ /lspd|lsposed|zygisk/) s += $2 }
        END { print s + 0 }
    ' "/proc/$p/smaps" 2>/dev/null)
    rss=$(awk '
        /^[0-9a-f]+-[0-9a-f]+ / { cur = $0 }
        /^Rss:/ { if (cur ~ /lspd|lsposed|zygisk/) s += $2 }
        END { print s + 0 }
    ' "/proc/$p/smaps" 2>/dev/null)

    n=$((n + 1))
    tot_pss=$((tot_pss + pss))
    tot_rss=$((tot_rss + rss))
    echo "  pid=$p  lspd Pss=${pss}KB Rss=${rss}KB  $name"
done

echo ""
echo "  ---- 被注入的进程数: $n ----"
echo "  lspd 映射合计: Pss=$((tot_pss / 1024)) MB  Rss=$((tot_rss / 1024)) MB"
echo "  （Pss 是"公平分摊"，多进程共享的库不会被重复计；Rss 是各进程实占）"

echo ""
echo "================ 2) LSPosed 自己的进程 ================"
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
        *lsposed*|*LSPosed*)
            st=$(awk '{print $14+$15+$16+$17}' "/proc/$p/stat" 2>/dev/null)
            rss=$(awk '/^Rss:/{s+=$2} END{print s+0}' "/proc/$p/smaps" 2>/dev/null)
            echo "  pid=$p  cpu=$(( ${st:-0} * 10 ))ms  Rss=$(( ${rss:-0} / 1024 ))MB  $c"
            ;;
    esac
done
echo "  （LSPosed 管理器不常驻；没列出来就说明没在跑）"

echo ""
echo "================ 3) 已启用的 LSPosed 模块 ================"
# LSPosed 的模块开关存在它自己的数据库里，这里只能看模块目录 + 管理器是否装了
ls -d /data/adb/modules/zygisk_lsposed 2>/dev/null && echo "  zygisk_lsposed: 已装"
for d in /data/adb/modules/*/; do
    b=$(basename "$d")
    [ "$b" = "zygisk_lsposed" ] && continue
    [ -f "$d/disable" ] && continue
    # 带 xposed 特征的模块（apk 里有 xposed_init 或 META-INF/xposed）
    if [ -d "$d" ]; then
        echo "  候选模块: $b"
    fi
done

echo ""
echo "================ 4) 系统整体（对照）================"
echo -n "  进程总数: "; ls /proc 2>/dev/null | grep -cE '^[0-9]+$'
echo -n "  内存总量: "; awk '/MemTotal/{printf "%.1f GB\n", $2/1048576}' /proc/meminfo
echo -n "  内存可用: "; awk '/MemAvailable/{printf "%.1f GB\n", $2/1048576}' /proc/meminfo
echo -n "  uptime:   "; cut -d. -f1 /proc/uptime
echo ""
echo "注：hook 调用的时间开销没法这样量 —— 要禁掉 LSPosed 重启做 A/B（对比 App 冷启动时间）。"
