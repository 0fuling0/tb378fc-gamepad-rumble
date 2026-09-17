#!/system/bin/sh
# 连续震动几次，方便用身体确认手柄真的在震
M=/data/adb/modules/tb378fc_gamepad_rumble

echo "=== 连续 3 次震动（每次 800ms 满幅值）—— 手柄应该有明显震感 ==="
for i in 1 2 3; do
  echo "  第 $i 次..."
  cmd vibrator_manager synced oneshot 800 255 >/dev/null 2>&1
  sleep 2
done
echo "done"

echo ""
echo "=== 模块日志 ==="
tail -8 "$M/gp.log"
