# TB378FC 手柄震动修复

修好联想小新 Pad Pro GT 13（TB378FC）HyperOS 3 移植包上**蓝牙游戏手柄不震动**的问题。

这是一个**独立的仓库 + 独立的 KernelSU 模块**（id `tb378fc_gamepad_rumble`），
只做这一件事，不碰系统其它部分。
（系统修复那一版在另一个仓库 `tb378fc-hyperos-fix-lite`，两者互不依赖。）

```bash
./build.sh                 # 自检 + 打包（纯 shell 模块，不需要 SDK/NDK/JDK）
# 产物：out/tb378fc_gamepad_rumble-v1.5.zip
```

---

## 一、为什么会不震：两层原因

### ① 移植包把开关留成了未设置

`Settings.System.vibrate_input_devices` 在本机是 `null`（= 0）。而 AOSP 的
`VibratorManagerService` 里有个 `InputDeviceDelegate`，它就是靠这个开关决定
**要不要把「输入设备（手柄）的振动器」注册进来**：

```java
public boolean updateInputDeviceVibrators(boolean vibrateInputDevices) {
    if (vibrateInputDevices == mShouldVibrateInputDevices) return false;
    mShouldVibrateInputDevices = vibrateInputDevices;
    mInputDeviceVibrators.clear();
    if (vibrateInputDevices) {
        mInputManager.registerInputDeviceListener(this, mHandler);
        for (int deviceId : mInputManager.getInputDeviceIds()) {
            InputDevice device = mInputManager.getInputDevice(deviceId);
            VibratorManager vm = device.getVibratorManager();
            if (vm.getVibratorIds().length > 0) mInputDeviceVibrators.put(device.getId(), vm);
        }
    }
    ...
}
```

关着时 `mInputDeviceVibrators` 为空 → `vibrateIfAvailable()` 直接返回 false
→ **手柄震动被静默丢弃**。

症状（实测）：

* `dumpsys vibrator_manager` 里 `vibrateInputDevices = false`、`Vibrators:` 为空
* `Recent vibrations` 里**全部**是 `IGNORED_UNSUPPORTED` —— 连输入法 / SystemUI 的
  `TOUCH` 触感也一起死，因为它们的震动走同一条被丢弃的路径
* 改成 1 之后状态变成 `FORWARDED_TO_INPUT_DEVICES`，`InputReader` 日志里能看到
  `sending vibrate deviceId=11, element=[duration=..., channels=[0 : N, 1 : N]]`

> 顺带排除一个误区：这条路径**不经过 vibrator HAL**，`InputDeviceVibratorManager`
> 直接用 `InputManager.getVibratorIds(deviceId)`。本机确实没有 vibrator HAL
> （平板自己的触感是死的，`EventHub` 报
> `Could not upload force feedback effect to device qcom-hv-haptics due to error 22`），
> 但那和手柄震动是两件独立的事。

### ② 内核驱动的 FF 报告字段错位

把开关打开后框架会正常下发震动，但手柄**仍然不震** —— 因为本机内核
`drivers/hid/hid-microsoft.c` 给 Xbox Series 手柄构造的输出报告，字段顺序和手柄
自己 HID 描述符声明的顺序不一致：

```c
struct xb1s_ff_report {          /* __packed，sizeof = 9 */
    __u8 report_id;              /* 3 */
    __u8 enable;                 /* ENABLE_WEAK|ENABLE_STRONG = 0x03 */
    __u8 magnitude[MAGNITUDE_NUM];  /* 4 字节，[2]=strong(左马达) [3]=weak(右马达) */
    __u8 duration_10ms;          /* U8_MAX */
    __u8 start_delay_10ms;       /* 0 */
    __u8 loop_count;             /* U8_MAX */
};
```

驱动按 `[duration][start_delay][loop_count]` 排；而**这个手柄的描述符声明的是**
`[Duration(0x50)][Loop Count(0xA7)][Start Delay(0x7C)]` —— **后两个字节相反**。

于是控制器把驱动发的 `... FF 00 FF` 读成「loop=0、delay=0xFF（2.55 秒延迟）」，
**永远震不起来**。

实测对照（同样的幅值，只换这两个字节的顺序）：

| 报告字节 | 含义 | 结果 |
|---|---|---|
| `03 03 00 00 ff ff ff 00 ff` | 驱动实际发的顺序 | **不震** |
| `03 0f 00 00 ff ff ff ff 00` | 描述符声明的顺序 | **震 ✓** |

> 判据：如果按驱动的顺序理解，`loop_count = 0xFF` 意味着 255 × 2.55s ≈ **10 分钟持续震动** ——
> 真发生的话不可能感觉不到。既然完全没感觉，就说明描述符的顺序才是控制器认的。

驱动是**内建**的（不在 `/sys/module/` 下，改不了），框架侧 `EventHub` 是 native，
两边都没法从用户态修改。

---

## 二、本模块怎么修

**不去改内核，而是"抄一遍"框架的震动意图，自己发一份格式正确的报告。**

```
框架要震动
   │
   ├─→ 内核 hid-microsoft → 发【字段错位】的报告 → 控制器忽略   ✗
   │
   └─→ 本模块监听到这个意图 → 按【正确顺序】重发一份 → 控制器震  ✓
```

具体做法：把框架下发的震动（设备号 / 时长 / 两个马达的幅值）解析出来，
按**手柄描述符声明的顺序**拼 9 字节输出报告，直接写进手柄的 hidraw 节点
（`/dev/hidraw0`）。写 hidraw 走的是 `hid_hw_output_report()` —— 和内核 FF 路径
**完全相同的最后一公里**（`hid_hw_output_report` → uhid `UHID_OUTPUT` → Android
蓝牙栈 → L2CAP → 手柄）。

报告格式（report ID 3，9 字节）：

```
[0] = 0x03              report id
[1] = 0x0F              使能位（低 4 bit）
[2..5] = 4 个幅值        [2]=左马达 [3]=右马达
[6] = 持续时间(×10ms)
[7] = 循环次数
[8] = 起始延迟(×10ms)
```

### 常驻进程与开销（实测）

手柄连着时 logcat/auto 模式共 **3 个进程**（看护 + bridge 主壳 + logcat），轮询模式 **2 个**
（看护 + bridge 主壳）；没手柄时三种模式都收敛到**只剩 1 个看护**：

| 状态 | 进程 | 实测（单核） | 占整机(8核) |
|---|---|---|---|
| 没有手柄（三种模式相同） | `service.sh` 看护 ×1 | **0.001%**（两次采样：10ms / 0ms 每 60 秒） | 0.0002% |
| 手柄连着（auto / logcat） | 看护 + bridge 主壳 + logcat | **0.13~0.15%** | ~0.018% |
| 手柄连着（poll） | 看护 + bridge 主壳 | **5.1~5.2%** | ~0.65% |

auto 健康时与仅 logcat 实测几乎一致（跑的就是同一个 logcat 桥），**备份机制本身零额外开销**。
轮询贵 35 倍是因为 `dumpsys` 是 Java 程序，每轮起一次 JVM。

「没有手柄」那档低到**测量不出来**（0~1 个 jiffy），所以「没手柄就零开销」这句话现在是
真的成立了 —— 最初是 0.30%，比有手柄时还贵。

手柄断开后 bridge 不是立刻消失：auto/logcat 模式靠 `read -t` 超时醒来重扫，连续 3 次
（约 30~40 秒）没有手柄就自己退出；轮询模式 20 个空轮（约 10 秒）退出。之后回到上面的
空闲态，等看护发现手柄接入再拉起。

各进程干什么、能不能省：

| 进程 | 作用 | 结论 |
|---|---|---|
| `logcat` | 事件源。没有它就只能轮询 `dumpsys input`（约 5% 单核） | logcat/auto 模式**必需** |
| `bridge.sh` 主壳 | 持有单实例锁、跑主循环（FIFO 读 logcat 行）、退出时清理 | 结构需要 |
| `service.sh` 看护 | 没手柄时不起 bridge（零开销）；bridge 挂了拉起来；logcat 订阅死了切兜底 | 有价值，**保留** |

> 历史包袱说明：主循环原来写在 `logcat | while read` 的**管道子壳**里（那时是 4 个进程）。
> 后来为了修「手柄断开后 bridge 永不退出」的 bug，主循环改用带超时的 `read -t`（管道里也能
> 用），但管道版还有个治不了的病：主壳退出后 logcat 作为管道上游会变成孤儿永远阻塞在
> socket 上，而且管道里拿不到对端 pid 去 kill。于是换成 FIFO + 后台 logcat —— 循环回到
> 主壳里跑，进程少一个，logcat 是自己 `&` 起的、退出时 `kill $LC_PID`，生命周期完全可控。

看护身上踩过两个坑（都实测踩到，已修）：

* **「没手柄」反而比「有手柄」贵**。看护原来每 20 秒跑一次 `sh bridge.sh --discover`，
  实测 **40ms**（新起一个 sh 解析 30KB 脚本 + `dumpsys input` 12ms + awk 扫一千多行），
  于是空闲时 **0.30%** 单核 —— 比 bridge 本体（0.1%）还贵，完全违背
  「没手柄就零开销」的初衷。
  → 先做一次**纯 sysfs 预筛**（`/sys/devices/virtual/misc/uhid/*/hidraw/hidraw*`，
  约 2ms，不起新进程、不跑 Java），通过才去跑昂贵的 discover → **0.30% → 0.07%**。
  预筛通过不等于一定是手柄（蓝牙键盘/鼠标也有 hidraw），那时照旧走完整 discover，
  只是偶尔多花 40ms。
* **`fork` 在这个设备上要 3~4ms，热循环里每一次都算数**。实测：`sleep 0` = 3ms、
  `cat` = 4ms、`/system/bin/log` = 4ms，而 **shell 内建 `read` = 0ms**。两处踩到：
  * `service.sh` 的 `cfg_raw` 还是老实现 `sed -n ... | tail -1` —— **2 个进程 + 1 个管道**，
    外面再套 `$( )` 就是 3 次 fork ≈ 12ms，而 `enabled()` 在循环里每轮都调。
    （bridge.sh 那边早就改成零 fork 的内建版了，注释里还写着"占了静止开销的一大半"，
    但**忘了同步到 service.sh**。）→ 改成 `cfg_read` 把值放进 `$CFG_VAL`，连子壳都省掉。
  * 心跳读取 `hb=$(cat "$HB")` → 内建 `read -r hb < "$HB"`。
  * 看护的巡检节拍 5 秒 → **10 秒**（bridge 挂掉很罕见，晚 10 秒拉起来无所谓；
    而"被关掉"那条路径根本不靠这里发现 —— `--set` 会直接调 `--apply` 停掉看护）。
  → 手柄连着时的开销 **0.75% → 0.23% 单核**。

* **换哪个 shell 跑，开销差 3~4 倍**。同一份脚本、同一个 10 秒巡检循环：
  `busybox sh` 跑看护 **20ms**/分，`mksh`（`/system/bin/sh`）跑 **70~80ms**/分。
  KernelSU 开机路径本来就用它自带的 busybox 起 `service.sh`，但 `--apply`
  （WebUI 改开关）原来写死了 `/system/bin/sh` —— 于是**改一次开关就换成一个贵 4 倍的
  看护**，直到下次开机才恢复。→ 统一走 `SH_BIN`（优先 `/data/adb/ksu/bin/busybox sh`，
  拿不到才退回 mksh），bridge 也一起。实测 busybox ash 跑 bridge 的二进制报告写入
  一切正常（`转发 -> deviceId=11 ...`）。

* **rescan 是循环里最贵的一步，而它跟日志流量无关**。用 bridge 的订阅串实测 30 秒
  只收到 **2 行**（全是心跳探针，`InputReader` 一行都没有），但循环子壳仍烧 50~70ms/分
  —— 钱花在每 10 秒一次的 `discover`（`dumpsys input` 12ms + awk 扫一千多行）上。
  → 先算一个**零 fork 的 sysfs 拓扑指纹**（uhid 目录名 + hidraw 节点，~1ms），
  没变就跳过 discover。手柄重连时 uhid 目录名会变（末尾 `.0001` → `.0002`），
  所以信号够灵敏。循环子壳降到 0~30ms。

* **订阅里那 4 个「低频探针」tag 可以摘掉了**。它们的唯一作用是"没震动时也一直有日志
  进来，好让心跳不空转"；自探针上线后就不需要了，而且屏幕亮着时它们一直在说话，
  白白把循环子壳唤醒。现在订阅只有 `InputReader TB378FC_HB` 两个 tag。

* **熄屏会被误判成「订阅死了」**。bridge 的心跳原来靠「收到 logcat 行」，而订阅的那几个
  低频探针在**熄屏后会全部安静** → 心跳停 300 秒 → 切轮询模式（贵 24 倍），而且原来
  **切过去就回不来**（只在手柄断开时才复位 `force_poll`）。实测 18:22 就是这么切过去的。
  → 看护每 30 秒往 logcat 写一条自己的探针（`log -t TB378FC_HB`，实测 8ms），bridge 的
  订阅里包含这个 tag，于是只要订阅活着心跳就一直新鲜；订阅真的死了探针也收不到，照样
  能发现。另外加了 `POLL_RETRY=600`：轮询持续 10 分钟就自动重试一次 logcat。

### 为什么两层都要做（实测对照）

只做 ① 是不够的 —— 这点值得写下来，因为它反直觉。实测（`tools/ab-forward.sh`）：

| 模块状态 | 触发方式 | 手柄 |
|---|---|---|
| **关**（bridge 已停，相关进程一个不剩） | 框架 `cmd vibrator_manager synced oneshot 3000 255` | **不震** |
| **开**（bridge 在跑） | 同一条命令 | **震** |
| —（对照：模块直接写 hidraw） | `bridge.sh --once 255 255 3000` | **震** |

三组里框架侧**都**把手柄震动下发下去了（`logcat -s InputReader` 能看到
`sending vibrate deviceId=11`）—— 差别只在于模块有没有把那 9 字节按正确格式补发。
所以 ①（打开框架开关）只是"让框架愿意往下发"，②（补发正确格式的报告）才是
"让它真的震起来"。**两层缺一不可。**

> ⚠️ 别被这个现象误导：如果发现"关掉开关手柄还能震"，先确认 bridge **进程真的没了**。
> 早期版本有个 bug 会让停用时删掉 `bridge.pid` 但进程没死，于是看起来像"关掉了还在震"。

### 改开关是即时生效的

`bridge.sh --set` 写完 config 后会顺手调 `service.sh --apply`：启用 → 立刻
`settings put system vibrate_input_devices 1` + 起看护；停用 → 先停看护、再停 bridge。
**不用重启设备**（早期版本必须重启，因为 service.sh 只在开机时被拉起一次）。

停用时**不**回滚 `vibrate_input_devices` —— 沿用 uninstall.sh 末尾写明的口径：它是
Android 的标准设置项，本机是被移植包留成了未设置；留着没有副作用。想还原：
`settings delete system vibrate_input_devices`。

### 触发方式：logcat 事件驱动（默认）+ 轮询兜底，`BRIDGE_MODE` 三档可切

config 的 `BRIDGE_MODE` 决定用哪种触发方式（WebUI 里有切换按钮，改完即时生效）：

| `BRIDGE_MODE` | 行为 | 实测开销（静止，手柄连着） | 延迟 |
|---|---|---|---|
| `auto`（默认） | logcat 为主；订阅被 logd 拒了自动切轮询；轮询常驻 10 分钟（`POLL_RETRY`）再切回 logcat | **0.13~0.15% 单核**（与仅 logcat 一致，备份零开销） | ≈0 |
| `logcat` | 只用 logcat；订阅死了看护只重启订阅，不切轮询 | **0.14~0.15% 单核** | ≈0 |
| `poll` | 只用轮询，不依赖 logd、不依赖内核的 `DEBUG_VIBRATOR` 编译开关 | **5.1~5.2% 单核**（整机 0.65%） | 最多 500ms（`IDLE_POLL_MS`） |

**「两种都开 = 互为备份」的正确含义**：auto **不是**两个实例同时跑 —— 两个 bridge 会同时转发，
手柄收到两份报告（实测踩过"每件事都成对出现"），而且轮询常驻要多烧 5% 单核。备份指的是
同一时刻只有一个在发，另一个待命、坏了由看护顶上。

**为什么默认 logcat**：`logcat` 是原生二进制，阻塞在 socket 上等日志时几乎不耗 CPU；
事件驱动、零延迟。本机内核编译时开了 `DEBUG_VIBRATOR`，框架每次下发震动都会打一行日志，
里面已含设备号/时长/幅值。轮询之所以贵，是因为 `dumpsys` 是 Java 程序（`app_process`），
每轮起一次 JVM。

**为什么还要轮询兜底**：`logd` 对每个缓冲区有**并发读者上限**。系统里 logcat 读者
一多，新的读者会**静默订阅不上** —— 进程在跑、socket 也建了、`/proc/<pid>/fd/1`
指向管道，但 `wchan` 停在 `__skb_wait_for_more_packets`，**一行都收不到，且没有任何报错**。
（这个坑排查了很久。）另外 `DEBUG_VIBRATOR` 是**编译期**常量，换内核可能就没了 ——
所以换 ROM 后手柄不震了，可以先切 `poll` 模式验证是不是这个原因。

**订阅死了怎么发现**：`InputReader` 只在真震动时才有日志，光靠它无法区分"这段时间没震动"
和"订阅根本是死的"。所以看护每 30 秒往 logcat 写一条自己的探针（`/system/bin/log -t
TB378FC_HB`，bridge 的订阅里含这个 tag），bridge 每收到一行（探针也算）就更新一次心跳文件。
看护每 10 秒检查心跳，超过 `HB_TIMEOUT=300` 秒没动 = 订阅死了 → auto 切轮询 / logcat
重启订阅。注意探针是"确认有手柄"之后才写的 —— 没手柄时 bridge 没跑，写了也没人看。

**⚠️ 主循环的 `read` 必须带超时（`read -t`），这个坑踩得很疼**：原来是无超时的阻塞 read，
所有检查（nopad 退出、拓扑重扫）都只在"有一行日志到达"时才执行 —— 而手柄断开后恰恰一行
都不会再有（没有震动事件，看护探针也停了）。实测：手柄断开后 bridge 永久空转（60 秒、
160 秒都不退出），日志里连一次检查的机会都没有。改成 `read -t $RESCAN` 后超时也醒来，
检查变成**时间驱动**。配套还把管道改成了 FIFO + 后台 logcat：管道版主壳退出后，logcat
会变成孤儿永远阻塞在 socket 上（"断开后 4 个进程挂着"有一半是它），而管道里拿不到对端
pid 去 kill；FIFO 方案里 logcat 是自己 `&` 起的，退出时 `kill $LC_PID` 干净利落。
busybox ash 的 `read -t` 超时返回 rc=1 但**保留旧值**，所以每轮要先清空变量再读。

### 怎么确认"连上的确实是手柄"

`discover()` 用**三条判据**，缺一不可：

| # | 判据 | 为什么 |
|---|---|---|
| 1 | `dumpsys input` 的 Input Reader 段里有 `SysfsRootPath` | 拿到 uhid 设备目录 |
| 2 | 该目录下有 `hidraw/hidraw*` 节点 | 有输出报告通道，报告能真的发出去 |
| 3 | **同段的 `Sources:` 里含 `GAMEPAD` 或 `JOYSTICK`** | **确实是手柄** |

第 3 条是必须的。只有 1)+2) 的话，接个蓝牙键盘 / 鼠标 / 自拍杆同样会被当成目标，
而它们收到那 9 字节的「手柄 rumble 报告」只会莫名其妙。

两个 Source 都接受，是因为有些手柄只报 `JOYSTICK` 不报 `GAMEPAD`（造了假设备验证过）；
而键盘 / 鼠标 / 触摸 / 笔都不报这两个，所以放宽不会误伤。

本机实测（唯一命中的是手柄）：

| 设备 | `Sources:` | 有 hidraw | 命中 |
|---|---|---|---|
| **Xbox Wireless Controller** | `KEYBOARD \| GAMEPAD \| JOYSTICK` | ✓ | **✓** |
| qcom-hv-haptics（平板触感） | `KEYBOARD` | ✗ | ✗ |
| NVTCapacitiveTouchScreen | `KEYBOARD \| TOUCHSCREEN` | ✗ | ✗ |
| NVTCapacitivePen（笔） | `KEYBOARD \| TOUCHSCREEN \| STYLUS` | ✗ | ✗ |
| pmic_resin / pmic_pwrkey / gpio-keys | `KEYBOARD` | ✗ | ✗ |

> **顺带澄清一件事**：平板**根本没有震动马达** —— `qcom-hv-haptics` 只是 SoC 里那个
> 触感控制器，而且它**没有 hidraw**，所以从来就没被映射过。
> 「给平板触摸转发震动」这件事从头到尾没有发生过。

> ⚠️ 判据里**故意不加** `Vibrator Input Mapper`。蓝牙重连后 `InputReader` 有时不给
> 手柄重建 `VibratorInputMapper`（见下面「已知问题」），加了会直接找不到手柄；
> 而 `GAMEPAD` + hidraw 已经足够精确。

### 设备号怎么对应到手柄的 hidraw

日志里的 `deviceId` 是 **InputReader 的编号**。`dumpsys input` 里**有两套编号**，
别混用：

| 段落 | 编号体系 | 手柄的值 |
|---|---|---|
| `Input Devices:` | InputManagerService | 12 |
| `Input Reader State` | **InputReader（日志/本模块用这个）** | **11** |

`Input Reader State` 段每个设备都带 `SysfsRootPath`，而 uhid 设备目录下有 hidraw：

```
  Device 11: Xbox Wireless Controller
    SysfsRootPath:     /sys/devices/virtual/misc/uhid/0005:045E:0B13.0001
      └── hidraw/hidraw0
```

所以一次 `dumpsys input` 就能建出「deviceId → /dev/hidrawN」的映射。
`qcom-hv-haptics` 这类设备也有 `Vibrator Input Mapper`，但没有 hidraw，会被自动跳过。

---

## 三、配置

改模块目录下的 `config`（或用 KernelSU 管理器的 WebUI）：

| 键 | 默认 | 说明 |
|---|---|---|
| `FIX_GAMEPAD_RUMBLE` | `1` | 总开关。关掉就不设 `vibrate_input_devices`、也不转发 |
| `IDLE_POLL_MS` | `500` | 轮询模式：静止时的间隔 |
| `ACTIVE_POLL_MS` | `120` | 轮询模式：震动中的间隔 |
| `REFRESH_MS` | `5000` | 连续震动时强制重发一次的间隔（防长震动中途断掉） |
| `EXIT_WHEN_NO_PAD` | `1` | 两种模式通用：没手柄时退出（省电）。logcat 模式约 3×`RESCAN_SECONDS` 秒、轮询模式约 20 轮后退出，等看护在有手柄时再拉起 |
| `BRIDGE_MODE` | `auto` | `auto` = logcat 主 + 轮询兜底（互为备份，同一时刻只有一个在发）；`logcat` = 只用 logcat，订阅死了只重启订阅；`poll` = 只用轮询（约 7% 单核，不依赖 logd） |
| `CHECK_SECONDS` | `20` | 看护进程检查"有没有手柄接入"的间隔 |
| `RESCAN_SECONDS` | `10` | 重新解析 deviceId → hidraw 映射的间隔 |

也可以建标记文件强制关：模块目录下 `touch disable` 或 `touch disable-gamerumble`。

---

## 四、排障

```bash
M=/data/adb/modules/tb378fc_gamepad_rumble

# 看状态（开关 / 守护进程 / 识别到的手柄与 hidraw 映射）
sh $M/bridge.sh --status

# 给 WebUI 用的 JSON
sh $M/bridge.sh --json

# 手动发一次震动（左幅值 右幅值 时长ms）—— 用来确认链路
sh $M/bridge.sh --once 255 255 1000

# 看映射
sh $M/bridge.sh --discover

# 日志
cat $M/gp.log
```

**排查顺序**：

1. `settings get system vibrate_input_devices` 必须是 `1`（不是就 `settings put system vibrate_input_devices 1`）
2. `sh $M/bridge.sh --discover` 要能列出 `11 /dev/hidraw0` 这样的行
   —— 空的话是手柄没连，或连了但内核没给 FF
3. `sh $M/bridge.sh --once 255 255 1000` 应该立刻震
   —— 不震说明 hidraw 写不进去（权限 / 手柄没连）
4. 都不震但 `--once` 震 → 看 `gp.log` 里有没有 `转发 ->` 行：
   * 没有 → 触发没接上。logcat 模式下检查心跳文件 `$M/.heartbeat` 是否在更新
     （不更新说明订阅被 logd 拒了，看 `service.sh` 有没有切到轮询模式）
   * 有 → 报告发出去但手柄没响应，多半是手柄固件版本差异，需要重新解析它的 HID 描述符

### ⚠️ 已知问题：蓝牙重连后手柄会失去 `Vibrator Input Mapper`

**症状**：手柄连着、内核侧 FF 也完好，但 `dumpsys input` 里手柄那段**没有**
`Vibrator Input Mapper:`，而且框架只给 `deviceId=5`（平板触感）发震动、**完全不给
`deviceId=11`（手柄）发**。

```bash
# 内核侧一切正常
cat /proc/bus/input/devices | grep -A2 Xbox    # B: FF=107030000 0   ← FF 还在
getevent -pl | grep -A1 "Xbox Wireless"        # FF (0015): FF_RUMBLE ...
dmesg | grep microsoft                          # input,hidraw0: BLUETOOTH HID v1.11 Gamepad

# 但框架侧丢了
dumpsys input | grep -A20 "Device .*Xbox"      # 没有 Vibrator Input Mapper 段
logcat -s InputReader                          # 只有 sending vibrate deviceId=5
```

**后果**：`InputDeviceDelegate` 靠 `getVibratorIds()` 判断要不要注册一个输入设备，
mapper 没了它就注册不上 → 框架从不给手柄发震动 → 本模块也监听不到。

**成因**（实测）：蓝牙断开重连后，`InputReader` 有时不会给手柄重建
`VibratorInputMapper`。开机时是好的（实测 16:12 那次开机正常），重连后丢。

**当前处理**：
* 本模块的 `discover()` **不依赖** `Vibrator Input Mapper`（只用 `SysfsRootPath` +
  hidraw），所以至少能识别出手柄、WebUI 也能看到映射 —— 不会误报"没手柄"。
* 但框架不发震动这件事绕不过去。**重启设备**可以恢复（开机时 `InputReader` 会重新建
  mapper）。

**待查**：能不能让模块自动恢复 —— 比如检测到这种情况时
`echo <dev> > /sys/bus/hid/drivers/microsoft/unbind && ... bind` 强制驱动重新 probe
（那样 `InputReader` 会重建 input 设备与 mapper）。但这会在游戏中途重建手柄，有风险，
需要先验证。

### 用到的设备信息（本机实测）

| 项 | 值 |
|---|---|
| 手柄 | Xbox Wireless Controller `045e:0b13`（Xbox Series，BLE） |
| 内核绑定 | `hid-microsoft`（`driver -> hid/drivers/microsoft`） |
| 设备路径 | `/devices/virtual/misc/uhid/0005:045E:0B13.0001` |
| input / event / hidraw | `input11` / `event11` / `/dev/hidraw0` |
| FF 能力 | `FF_RUMBLE FF_PERIODIC FF_SQUARE FF_TRIANGLE FF_SINE FF_GAIN` |

---

## 五、已知限制

* **依赖内核开了 `DEBUG_VIBRATOR`**（logcat 模式）。这台机器的内核开了；换内核后如果
  没开，logcat 模式会收不到震动日志，心跳会停，`service.sh` 会在 60 秒内自动切到
  轮询模式（不依赖它）。
* **必须有个常驻进程**。每次震动时唯一会运行的就是内核那条（字段错位的）FF 路径，
  用户态没有任何"每帧都执行"的钩子 —— 要补发正确格式的报告就必须有东西在跑。
  已经尽量压到最低：logcat 模式 0.1% 单核、没手柄时进程退出。
* **只针对 Xbox Series（`045e:0b13`）验证过**。其它手柄如果内核驱动的报告顺序是对的，
  本模块会**重复发一份**（手柄收到两次同样的报告，多一次 BT 流量，不会更糟）。
  如果确认不需要，用 `disable-gamerumble` 关掉。

---

## 六、目录结构

```
├── build.sh                 构建（语法 / 未定义函数 / WebUI 自检 + 打包，纯 shell 模块）
├── module/                  KernelSU 模块（zip 根目录就是这里）
│   ├── module.prop
│   ├── config               运行配置
│   ├── bridge.sh            守护进程本体（logcat / 轮询两种模式）
│   ├── parse-input.awk      dumpsys input 的解析（抽成独立文件，方便单测）
│   ├── service.sh           开机入口 + 看护（选模式、盯心跳、按手柄接入启停）
│   ├── customize.sh         安装期（权限位 + 升级时合并 config）
│   ├── uninstall.sh         卸载（收干净守护进程）
│   └── webroot/index.html   KernelSU WebUI
└── tools/                   构建工具 + 开发期测量/测试脚本（都不进包）
    ├── pack_zip.py          打包模块 zip（没有 zip 命令时的兜底，权限位从 git index 读）
    ├── check-helpers.py     静态检查"被调用但未定义"的内部函数（会剥离内嵌 awk）
    ├── cleanup-test.sh      清掉测试残留的 logcat / bridge 进程
    ├── measure-cpu.sh       量守护进程的实际 CPU 占用
    ├── measure-lsposed.sh   量 LSPosed 在本机的开销（对照用）
    ├── bench.sh             对比几种"拿震动状态"方式的 CPU 开销
    ├── parse-test.sh        用真实日志行验证解析逻辑
    ├── probe-ids.sh         采集"手柄识别"需要的设备数据
    ├── diag.sh              看护卡住时的诊断
    ├── status.sh            上机状态速查（开关/进程/日志/心跳/识别/配置 一把梭）
    ├── e2e-test.sh          端到端验证：框架下发震动 → 看它发给谁 → 模块有没有转发
    ├── feel-test.sh         连发几次震动，方便用身体确认手柄真的在震
    ├── webui-selftest.js    WebUI 自检（DOM 桩跑真页面：渲染 / 交互 / 状态文案）
    ├── webui-preview.py     生成桌面可直接打开的 WebUI 预览页（不用刷模块）
    ├── diag-pid.sh          pidfile / 进程树诊断（查看护死循环那类问题用）
    ├── apply-test.sh        开关即时生效 + 快速连拨（复现「每 25 秒重启一次」用）
    ├── conc-test.sh         并发调用 discover / --json，验证映射不会踩出重复条目
    ├── ab-forward.sh        A/B 对照：转发到底需不需要（见「为什么两层都要做」）
    └── ab-test.sh           logcat 流式在两种启动方式下是否都能收到行
```

> `tools/pack_zip.py` 和 `tools/check-helpers.py` 与 `tb378fc-hyperos-fix-lite` 仓库
> 里的是同一份（各存一份，保证本仓库自包含）。改动时两边都要同步。

---

## 七、发布

推一个 `v*` 的 tag 就会触发 `.github/workflows/release.yml`：自检 → 打包 → 上传
artifact → 建 GitHub Release 并把 zip 附上。

```bash
# 1) 先把 module/module.prop 的 version 改成要发的版本
#    （注意它带 v 前缀：version=v1.5）
# 2) 提交，然后打 tag —— tag 必须和 version 完全一致
git tag v1.5
git push origin v1.5
```

> ⚠️ workflow 里有一步专门校验「tag 与 `module.prop` 的 `version` 一致」，不一致会
> **直接失败**。这是防「tag 是 v1.4、包里却是 v1.3」这种版本错位 —— 发出去就不好回收了。

也可以在 Actions 页面手动 `Run workflow`（tag 留空就用 `module.prop` 里的 `version`）。
workflow 是幂等的：Release 已存在时只覆盖附件，重跑不会报 `already exists`。

纯 shell 模块，**不需要 Android SDK / NDK / JDK**，`build.sh` 几秒出包。

---

## 八、WebUI

### 风格与系统修复 Lite 版保持一致

两边的 WebUI 用的是**同一套设计令牌** —— 15 个 CSS 变量（`--bg` / `--card` / `--line` /
`--fg` / `--fg2` / `--fg3` / `--ok` / `--bad` / `--warn` / `--accent` / `--mono` …）
逐字相同，深色模式也同一套；`.card` / `.num` / `.title` / `.desc` / `.st` / `.sw` /
`.btn` / `.note` / `.bar` / `.log` / `.mark` / `.foot` 这些共用类的声明也逐字相同。

结构也一致：**编号徽标 + 标题 + 副标题 + 状态胶囊**，开关在卡片右上角。

```
① 打开「输入设备振动」开关      [开关]
② 补发手柄 FF 报告              [自动]
③ 手柄与链路                    （映射 + 测试震动按钮）
```

和 Lite 相比只有两处**故意**的差别（都是修正，不是风格）：
* `.st` 多了 `max-width:100%` —— 本模块的状态文案更长，不加会溢出卡片
* `.sw` 多了 `padding:0` —— `<button>` 的默认内边距会把绝对定位的滑块顶偏

### 在桌面上看（不用刷模块）

```bash
python3 tools/webui-preview.py                  # 手柄模块 → out/webui-preview-rumble.html
python3 tools/webui-preview.py --target lite    # Lite 模块（对比风格用）
python3 tools/webui-preview.py --dark           # 强制深色（复用页面自己的深色令牌）
```

它只往页面里注入一个**假的 `ksu.exec`**（返回一组像真机一样的 JSON），
**页面本身的 HTML/CSS 一个字都不改** —— 所以看到的就是真机上的样子。

### 自检

```bash
node tools/webui-selftest.js
```

用极简 DOM 桩把 `module/webroot/index.html` **真跑一遍**（8 个场景），
断言的都是踩过坑的约束，比如：

* 拨一次开关**必须只发一条** `--set`（发两条 = 双重写入）
* 「测试震动」只能走 `--once`，**不能顺带写 config**
* ② 的状态文案要有判别力：开关关着 → 「不会启动」；没手柄 → 「等待手柄接入」；
  在跑 → 「运行中」；有手柄却没跑 → 才是「未运行」。
  （前两种不该报成故障，否则用户会以为坏了）
* 副标题不能出现裸的「开」/「关」—— Lite 那边真踩过：`停 BPF 监视器  开 · 已停`
  里的「开」是"这项修复启用了吗"，紧跟在标题后面被读成"监视器：开"。

`build.sh` 会跑它；没装 node 就跳过。
