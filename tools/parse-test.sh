#!/system/bin/sh
# 用真实日志行验证 logcat 模式的参数展开解析（全部 shell 内建，不起任何进程）
test_line() {
    line="$1"
    id="${line##*deviceId=}"; id="${id%%,*}"
    case "$id" in ''|*[!0-9]*) echo "  ✗ id 解析失败"; return ;; esac
    dur="${line##*duration=}"; dur="${dur%%ms*}"
    case "$dur" in ''|*[!0-9]*) dur=0 ;; esac
    l="${line##*channels=[0 : }"; l="${l%%,*}"; l="${l%%]*}"
    case "$l" in ''|*[!0-9]*) l=0 ;; esac
    r="${line##*1 : }"; r="${r%%]*}"
    case "$r" in ''|*[!0-9]*) r=0 ;; esac
    echo "  id=$id dur=$dur 左=$l 右=$r"
}
echo "A 正常两通道:"
test_line 'D/InputReader( 3005): nextStep: sending vibrate deviceId=11, element=[duration=1000ms, channels=[0 : 255, 1 : 255]]'
echo "B 另一设备:"
test_line 'D/InputReader( 3005): nextStep: sending vibrate deviceId=5, element=[duration=3000ms, channels=[0 : 200, 1 : 120]]'
echo "C 单通道:"
test_line 'D/InputReader( 3005): nextStep: sending vibrate deviceId=11, element=[duration=500ms, channels=[0 : 128]]'
echo "D 小幅值:"
test_line 'D/InputReader( 3005): nextStep: sending vibrate deviceId=11, element=[duration=800ms, channels=[0 : 60, 1 : 90]]'
echo "E 非震动行（应识别不出 id）:"
test_line 'D/InputReader( 3005): nextStep: scheduled timeout in 3000ms'
echo "F 停止行:"
line='D/InputReader( 3005): stopVibrating: sending cancel vibrate deviceId=11'
case "$line" in
    *"stopVibrating: sending cancel vibrate deviceId="*) echo "  ✓ 匹配到停止行" ;;
    *) echo "  ✗ 停止行没匹配上" ;;
esac
