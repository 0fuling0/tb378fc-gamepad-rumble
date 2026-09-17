# 解析 `dumpsys input` 的 "Input Reader State" 段，输出每个"有 FF 且能拿到 hidraw"
# 的设备的当前状态，一行一个：
#
#     <deviceId> <SysfsRootPath> <vibrating:0/1> <duration_ms> <ch0> <ch1>
#
# 为什么只取这些设备：判据是同时出现 `Vibrator Input Mapper:`（内核给了 FF）
# 和 `SysfsRootPath:`（下面能解析出 hidraw 节点）。qcom-hv-haptics 这类设备也有
# Vibrator Input Mapper，但它没有 hidraw，会被调用方自动跳过。
#
# 注意 deviceId 用的是 **InputReader 的编号**（本段里的 `Device N:`），
# 它和 `Input Devices:` 段里 InputManagerService 的编号**不是同一套**，别混用。
/^  Device [0-9]+: / {
    if (dev != "") emit();
    dev = $2; sub(":", "", dev);
    ff = 0; root = ""; vib = 0; dur = ""; l = ""; r = "";
    next;
}
/Vibrator Input Mapper/ { ff = 1; next }
/SysfsRootPath:/        { root = $2; next }
/Vibrating: true/       { vib = 1; next }
/Pattern:/ {
    if (match($0, /duration=[0-9]+/))  dur = substr($0, RSTART + 9, RLENGTH - 9);
    # ⚠️ 边界要写「前面不是数字」而不是「前面是空格」—— 通道 0 前面是 `[`
    #    （"channels=[0 : 255"），写成空格会把通道 0 整个漏掉（实测踩过）。
    #    这样同时能挡住 "10 : 5" 被误当成通道 0。
    if (match($0, /[^0-9]0 : [0-9]+/)) l   = substr($0, RSTART + 5, RLENGTH - 5);
    if (match($0, /[^0-9]1 : [0-9]+/)) r   = substr($0, RSTART + 5, RLENGTH - 5);
    # 单通道（"channels=[0 : 128]"）→ 镜像到右，否则右马达会被静音
    if (l != "" && r == "")            r   = l;
    next;
}
function emit() {
    if (dev != "" && ff && root != "") print dev, root, vib, dur, l, r;
}
END { emit() }
