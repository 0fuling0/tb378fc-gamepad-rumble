#!/system/bin/sh
# 复现这个坑：同名 shell 函数遮蔽 log 命令
HB_TAG="TB378FC_HB_TEST"
LOG=/data/local/tmp/ping-test.log
rm -f $LOG
log() { echo "$(date '+%F %T') [test] $*" >> "$LOG"; }

echo "  --- 错误写法：log -t ... （会被函数吃掉）---"
log -t "$HB_TAG" "wrong-way-$$"
logcat -d -b all -v brief -s "$HB_TAG" 2>/dev/null | grep -c "wrong-way-$$" | sed 's/^/    logcat 里收到的条数: /'
echo -n "    gp.log 里多了什么: "; tail -1 $LOG

echo ""
echo "  --- 正确写法：/system/bin/log -t ... ---"
/system/bin/log -t "$HB_TAG" "right-way-$$"
sleep 1
logcat -d -b all -v brief -s "$HB_TAG" 2>/dev/null | grep -c "right-way-$$" | sed 's/^/    logcat 里收到的条数: /'
logcat -d -b all -v brief -s "$HB_TAG" 2>/dev/null | grep "right-way-$$" | sed 's/^/      /'
rm -f $LOG
