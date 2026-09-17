#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的模块目录里不会保留它）
ui_print " "
ui_print "- TB378FC 手柄震动修复 v1.0"
ui_print "- 只做一件事：让蓝牙游戏手柄的震动真正生效"
ui_print "- ① 打开 Settings.System.vibrate_input_devices（移植包留成了未设置）"
ui_print "- ② 跟着内核 InputReader 的震动日志，把框架的震动意图按正确格式重发给手柄"
ui_print "- 不碰系统其它部分；可用 WebUI 开关或 disable-* 标记文件关闭"
ui_print "- 作者: ACLaniakea, fuling"
ui_print " "

chmod 0755 "$MODPATH"
chmod 0644 "$MODPATH"/*.prop "$MODPATH"/config 2>/dev/null

# ⚠️ KernelSU 的安装器**没有** Magisk 的 set_perm / set_perm_recursive（会静默失效），
# 必须用普通 chmod。少了这一步脚本根本跑不起来。
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 644 "$MODPATH"/webroot/* 2>/dev/null

# ---- 升级时保住用户已调好的开关，同时补上**新增**的键 ----
# 上一版模块（以及本仓库的 Lite 模块）是直接 `cp` 旧 config 覆盖新 config 的，
# 后果是：包内新增的键在升级后**不存在**，而缺键的语义是"关" —— 于是新功能
# 静默不生效（实测：Lite 模块加 FIX_GAMEPAD_RUMBLE 后，升级上来仍是关的）。
# 这里改成以**包内的 config 为底**，只把设备上已有的键值覆盖回去：
#   * 新键 → 用包内默认值 ✓
#   * 老键 → 保留用户设过的值 ✓
MODID="$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -1)"
[ -n "$MODID" ] || MODID="$(basename "$MODPATH")"
OLD_CFG="/data/adb/modules/$MODID/config"
NEW_CFG="$MODPATH/config"

if [ -f "$OLD_CFG" ] && [ -s "$OLD_CFG" ] && grep -q '^[A-Za-z_][A-Za-z0-9_]*=' "$OLD_CFG" 2>/dev/null; then
    merged="$MODPATH/.config.merged"
    cp -f "$NEW_CFG" "$merged" 2>/dev/null
    n=0
    # 只处理"键=值"行；注释行一律用包内的（文档会随版本更新）
    while IFS= read -r line; do
        case "$line" in
            [A-Za-z_]*=*)
                k="${line%%=*}"
                v="${line#*=}"
                if grep -q "^$k=" "$merged" 2>/dev/null; then
                    # 用 awk 按字面替换，避免值里的 / & \ 被 sed 解释
                    awk -v k="$k" -v v="$v" '
                        index($0, k "=") == 1 { print k "=" v; next } { print }
                    ' "$merged" > "$merged.tmp" && mv -f "$merged.tmp" "$merged"
                    n=$((n + 1))
                fi
                ;;
        esac
    done < "$OLD_CFG"
    if mv -f "$merged" "$NEW_CFG" 2>/dev/null; then
        ui_print "- 已保留你之前的开关设置（$n 项），并补齐了包内新增的键"
    else
        rm -f "$merged" 2>/dev/null
        ui_print "- 提示: 旧 config 合并失败，本次用默认设置"
    fi
else
    ui_print "- 全新安装：使用默认设置"
fi
