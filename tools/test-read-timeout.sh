#!/system/bin/sh
# 测 busybox ash / mksh 的 read 支不支持 -t（超时）—— 支持的话，
# logcat 订阅循环就能「没有日志也定期醒来」去做重扫/退出判断。
BB=/data/adb/ksu/bin/busybox

echo "=== busybox ash ==="
$BB sh -c 'read -t 2 x < /dev/zero; echo "  read -t 2 返回码=$?（124/1=超时可用，其它=不支持）"' 2>&1 | sed 's/^/  /'
echo "  --- 实测：管道里 3 秒没有数据时 read -t 2 会不会返回 ---"
$BB sh -c 'i=0; ( sleep 3; echo hi ) | { while [ $i -lt 1 ]; do if read -t 2 line; then echo "  收到: $line"; else echo "  read -t 2 超时返回（可用 ✓）"; fi; i=1; done; }' 2>&1 | sed 's/^/  /'

echo ""
echo "=== /system/bin/sh (mksh) ==="
/system/bin/sh -c 'read -t 2 x < /dev/zero; echo "  read -t 2 返回码=$?"' 2>&1 | sed 's/^/  /'

echo ""
echo "=== 对照：不带 -t 时 busybox ash 的 read 行为 ==="
$BB sh -c '( sleep 1; echo hi ) | { read line; echo "  收到: $line"; }' 2>&1 | sed 's/^/  /'
