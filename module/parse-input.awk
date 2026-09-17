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
    if (match($0, /0 : [0-9]+/))       l   = substr($0, RSTART + 4, RLENGTH - 4);
    if (match($0, /1 : [0-9]+/))       r   = substr($0, RSTART + 4, RLENGTH - 4);
    next;
}
function emit() {
    if (dev != "" && ff && root != "") print dev, root, vib, dur, l, r;
}
END { emit() }
