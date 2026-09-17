#!/system/bin/sh
# 受控对比：logcat 流式输出到管道，在两种启动方式下是否都能实时收到行
#   A: stdin = 调用者的 stdin（终端）
#   B: stdin = /dev/null（守护进程的启动方式：setsid ... </dev/null &）
# 两组都用同一个过滤条件，跑同样久，然后比较收到多少行。

rm -f /data/local/tmp/ab-a.txt /data/local/tmp/ab-b.txt

# --- A ---
sh -c 'logcat -b all -v brief -s InputReader 2>/dev/null | while IFS= read -r l; do echo "$l" >> /data/local/tmp/ab-a.txt; done' &
PA=$!

# --- B ---
sh -c 'logcat -b all -v brief -s InputReader 2>/dev/null | while IFS= read -r l; do echo "$l" >> /data/local/tmp/ab-b.txt; done' </dev/null &
PB=$!

sleep 2
echo "A pid=$PA  B pid=$PB"
sleep 3

kill $PA $PB 2>/dev/null
pkill -x logcat 2>/dev/null
sleep 1

echo "--- A (stdin=终端) 收到 ---"
wc -l < /data/local/tmp/ab-a.txt 2>/dev/null || echo 0
head -3 /data/local/tmp/ab-a.txt 2>/dev/null
echo "--- B (stdin=/dev/null) 收到 ---"
wc -l < /data/local/tmp/ab-b.txt 2>/dev/null || echo 0
head -3 /data/local/tmp/ab-b.txt 2>/dev/null
