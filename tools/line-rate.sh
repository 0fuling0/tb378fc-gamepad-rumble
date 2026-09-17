#!/system/bin/sh
OUT=/data/local/tmp/line-rate.out
rm -f $OUT
echo "用 bridge 现在那条过滤串订阅 30 秒，数一下收到多少行："
logcat -b all -v brief -T 1 -s InputReader TB378FC_HB > $OUT 2>/dev/null &
LP=$!
sleep 30
kill -9 $LP 2>/dev/null
pkill -f "InputReader TB378FC_HB" 2>/dev/null

n=$(wc -l < $OUT)
echo "  30 秒收到 $n 行  →  约 $(awk -v n=$n 'BEGIN{printf "%.1f", n/30}') 行/秒"
echo ""
echo "  按 tag 分类："
sed 's/.*[A-Z]\///; s/(.*//' $OUT | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
echo ""
echo "  前 6 行样本："
head -6 $OUT | sed 's/^/    /'
rm -f $OUT
