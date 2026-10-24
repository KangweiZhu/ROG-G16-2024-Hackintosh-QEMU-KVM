# 踩坑记录

下面每一条都是搭这套环境时真实遇到的问题（锐龙 AI 9 HX 370 + RTX 4060 Laptop，Arch Linux，KDE Plasma 6.8 Wayland，
QEMU 11.1，macOS 15.8.1，NullMoth 驱动 2.5.3）。格式都一样：看到什么、为什么、脚本里怎么处理的。

[English](troubleshooting.md)

## 装 macOS 阶段

### macOS 开机没多久就 panic 或重启，宿主机日志里一堆 `kvm: ignored rdmsr`
macOS 会去读 KVM 没模拟的 MSR。**解决：** `options kvm ignore_msrs=1`（`/etc/modprobe.d/kvm.conf`，`host.sh` 第 4 项）。

### 没有 `dmg2img`，QEMU 也不支持 LZFSE，`BaseSystem.dmg` 怎么启动？
其实不用转换。OpenCore 能直接从 FAT 分区里的 `com.apple.recovery.boot/` 启动 dmg。`scripts/mkrecovery.py` 用
pyfatfs 做一块这样的 FAT32 镜像，不需要 root，也不用挂 loop 设备。挂载时用 `snapshot=on` 当只读盘用
（SATA 设备上写 `readonly=on` 会报 “Block node is read-only”）。

### OpenCore 菜单里找不到恢复盘
OSX-KVM 开了 `HideAuxiliary`，在菜单里按一下**空格**，`RECOVERY (dmg)` 就出来了。

### 安装进度条 20 多分钟不动，QEMU 占满 CPU，磁盘却没有读写
当时 7 个 vCPU 停在内核的同一个地址空转，vCPU 0 停在 UEFI 运行时代码里。看起来很像内核 panic 之后正在往 NVRAM
写崩溃信息（和下一条的情况一模一样，那次能读到 panic 报告）。安装阶段具体是什么原因没查到；用 QMP 发了一次
`system_reset`（往 `state/qmp.sock` 发 `{"execute":"system_reset"}`），安装就自己接着跑完了。

### 换成 `iMacPro1,1` 之后，`AppleIntelMCEReporter` 里 panic
报错是 `AppleIntelMCE::Controller::~Controller + 0x8c`，`CR2 0x8` 的缺页。苹果的 MCE 驱动只在 iMac Pro / Mac Pro 的
board-id 上加载，在虚拟机里会空指针崩溃。OSX-KVM 其实带了 `MCEReporterDisabler.kext`，但 config.plist 里写的路径是
`AppleMCEReporterDisabler.kext`，文件名对不上，所以从来没加载过（iMac19,1 用不到它，所以以前没人发现）。
**解决：** `opencore/patch-config.py` 把路径改对了。

**看不到 panic 的时候怎么查：** 用 OSX-KVM 原版引导盘进系统
（`OPENCORE_IMG=state/OSX-KVM/OpenCore/OpenCore.qcow2 scripts/boot-macos.sh`），然后 SSH 进去看
`/Library/Logs/DiagnosticReports/Kernel-*.panic`。也可以 `EXTRA_BOOT_ARGS="-v debug=0x100" opencore/build.sh`，
这样 panic 会停在屏幕上，不会自动重启。

## 把显卡交给虚拟机

### NullMoth 的 `install.sh` 报 `STOP: no NVIDIA GPU found on PCI`
它装之前会检查系统里有没有 N 卡。所以顺序是先直通（`PASSTHROUGH=1`），再装驱动；装的时候仍然用 `imacpro` 那块引导盘。

### `host.sh on` 拒绝执行：KWin/Xwayland 还在用显卡
KDE Plasma（Wayland）下 KWin 会打开所有 DRM 设备，而很多笔记本的 HDMI 口就接在独显上。KWin 占着的时候硬卸 nvidia，
轻则卡住，重则整个桌面会话崩掉。要两项设置（`host.sh` 第 1、2 项），然后注销再登录：
- `KWIN_DRM_DEVICES=<核显>`：让 KWin 只用核显。这个变量用冒号分隔多个设备，所以不能用
  `/dev/dri/by-path/pci-0000:…` 这种带冒号的路径；需要的话 `host.sh` 会建一个不带冒号的 udev 软链接。
- 只给 KWin 服务设 `__EGL_VENDOR_LIBRARY_FILENAMES=…/50_mesa.json`。只有上一条的时候，KWin 还是会通过 glvnd
  先加载 NVIDIA 的 EGL（`10_nvidia.json` 排在前面），在独显上留一个 7 MiB 的上下文（`nvidia-smi` 里能看到
  `kwin_wayland C+G`）。

代价是：这两项开着的时候，宿主机桌面用不了接在独显上的接口。

### QEMU 报 `vfio … Cannot allocate memory`，或者加了 `limits.d` 之后 `ulimit -l` 还是 8192
VFIO 直通要锁住虚拟机的全部内存。桌面会话是 systemd 用户实例拉起来的，不走 `pam_limits`；而且开了
`loginctl enable-linger` 的话，注销重登也不会重启用户实例。**解决：** 给 `user@.service` 加 `LimitMEMLOCK=infinity`
（第 3 项，重启后生效）。在那之前，`host.sh on` 会用 `prlimit` 临时放开执行它的那个终端。

另外 `nvidia-powerd` 也会占着设备，`host.sh` 会先把它停掉。

## 直通启动

### macOS 能开机，但看不到显卡；QMP 的 `query-pci` 显示 BAR 地址是 `-1`
RTX 4060 Laptop 的 BAR1 有 8 GiB（开了 Resizable BAR）。OVMF 默认的 64 位 MMIO 窗口放不下，干脆所有 BAR 都没分配。
**解决：** `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536`。

### 显卡挂在 `pcie-root-port` 后面，macOS 能看到桥，桥后面却什么都没有
`ioreg` 里是 `IOPCIHotPlug = Yes`、`IOPCISlotDevicePresent = No`、`IOPCIExpressSlotStatus = 0`，链路状态里也没有
DLLLA：macOS 认为插槽是空的，根本不往下扫。加 `hotplug=off` 也没用。**解决：** 显卡直接挂在 `pcie.0` 根总线上，
OSX-KVM 的直通文档也是这么接的。

### QEMU 直接退出：`KVM_SET_USER_MEMORY_REGION failed, slot=12, start=0x8209700000000000, size=0x200000000: Invalid argument`
显卡挂到根总线后，macOS 重新配置 PCI 时往那个 8 GiB BAR1 的高 32 位写了一个 32 位地址，KVM 拒绝映射，QEMU 就退出了。
NullMoth 的 README 也提醒过，固件给的大 BAR 会让 PCI 配置失败。**解决：** 交给虚拟机之前，在宿主机上把 BAR1 缩到
256 MiB（`resource1_resize`，`host.sh` 第 6 项）。显存还是 8 GB，驱动日志是 `BAR1 256 MB, VRAM 8188 MB`。
`host.sh off` 会恢复原来的大小。

### WindowServer 无限重启：`CoreDisplay_CreateDisplayForCGXDisplayDevice` 断言失败
同一个现象，前后遇到了两个不同的原因：
1. **两个帧缓冲打架。** 开机画面在 `vmware-svga` 上的时候，macOS 会同时有固件帧缓冲（`IONDRVSupport`，`.Display_boot`，
   占 0 号）和 `NVRMFB`。NullMoth 的 README 说用 OpenCore 的 `Kernel → Block` 屏蔽 IONDRVSupport，但这一招只对
   Boot KC 里的 kext 有效，而 IONDRVSupport 是从 System KC 加载的，屏蔽不掉。**解决：** 直通模式下干脆不加虚拟显卡
   （`-vga none -display none`），OVMF 和 OpenCore 的画面改由显卡自己的 GOP 从它的接口输出。
2. **被判成“无头”显卡。** 日志里是 `NVMTLDriver: headless GPU: no device for WindowServer`。驱动会等 60 秒，
   要是还没等到显示器，就认为这张卡不接屏幕（那是给屏幕接在核显上的笔记本设计的），不让 WindowServer 用它。
   而在虚拟机里，显卡点亮接口要 100 秒左右，60 秒的期限先到了。**解决：** 启动参数加 `-nvaccelnoheadless`。

### HDMI 有信号，但屏幕一直是黑的
和上一条是同一类问题：去看 `/Library/Logs/DiagnosticReports/WindowServer-*.ips` 和
`log show --predicate 'process == "WindowServer"'`。

### 给 QEMU 加了 `model-id=<你的 CPU>` 之后，开机报 “not supported”
改 CPUID 里的处理器名称会让 macOS 起不来，别改。想在“关于本机”里显示自己的 CPU 名称，用 `CPU_NAME`
（交给 RestrictEvents 处理）。

## 键鼠

### OpenCore 菜单一直停着，而且默认选的是 “EFI”
“EFI” 其实是 OpenCore 自己所在的那块盘。直通模式下没有窗口可以操作。**解决：** `nvidia` 引导盘只扫描 SATA 上的
APFS，并且不显示菜单（`ScanPolicy 0x10103`，`ShowPicker false`）；需要菜单的时候（比如进恢复模式）用 `imacpro` 那块盘。

### 直通引导盘还是停在了选盘界面
evdev 兜底开着的话，键盘一开机就归虚拟机了，这时候你随手按的键（典型的就是按左右 Shift 想切回来）会被 OpenCore 收到，
它就算设了 `ShowPicker false` 也会把菜单弹出来，然后一直等。**解决：** `nvidia` 引导盘关掉按键检测
（`PollAppleHotKeys false`），并且用这块盘启动时，`boot-macos.sh` 晚 20 秒再交出键鼠。验证方法：开机前 14 秒用 QMP
连续发 Shift、Esc、回车、空格，照样自己进系统。

### 停在登录界面，没有键鼠可用
Deskflow 要登录之后才会启动。**解决：** 设置自动登录（`scripts/guest.sh autologin`，前提是 FileVault 关着），
再加上 evdev 兜底。

### evdev 兜底：选盘界面里鼠标动不了
鼠标是相对坐标，`usb-tablet` 只认绝对坐标，所以得另加一个 `usb-mouse`。要是开机之后再热插，固件已经枚举完 USB，
看不到它。**解决：** `boot-macos.sh` 开机时就带上 `usb-mouse`。

### evdev 兜底：只有一个键盘上的左右 Shift 能切换
`input-linux` 是按设备分别检测切换键的。**解决：** 每个设备都设 `grab_all=on` 和切换键（`scripts/qmp.py input-attach`）。
默认的左右 Ctrl 在没有右 Ctrl 的键盘上（比如 HHKB）用不了，所以改成了左右 Shift。

### Deskflow 1.27 报 `unknown computer name "linux"` / “Your server config has a screen section…”
从 1.27 开始，屏幕列表不再写在服务端配置的 `section: screens` 里（写了会被忽略），而是写在设置文件的
`[computer_<名字>]` 分组里。参考 `deskflow/linux-Deskflow.conf.in`。

### Deskflow 连上了，但鼠标从上边缘过不去（KDE Wayland）
上边缘的输入捕获屏障在这台机器上从来没触发过，左右边缘没问题。`deskflow/server.conf` 里三条边都连上了。

### macOS 上的 Deskflow 突然不工作，窗口显示 “Deskflow is not running”
遇到过一次：登录后 10 秒左右报 `uncaught exception ... event queue`，客户端以退出码 6 退出，而 Deskflow 的窗口程序
不会把它重新拉起来。**解决：** `scripts/guest.sh deskflow` 装的登录项同时是个看门狗，每 30 秒检查一次，
客户端不在就重启 Deskflow。

### macOS 登录后 Deskflow 没有自动连接
被一个“要不要检查更新”的对话框挡住了，客户端起不来。两边的设置里都已经关掉：`enableUpdateCheck=false`。

### 屏幕共享（VNC）能连上，但画面是黑的
日志里是 `ScreensharingAgent: Cannot get shareable content` / `replayd: TCC Disallow`：用命令行打开的屏幕共享
拿不到截屏权限。在“系统设置 → 通用 → 共享”里把屏幕共享关掉再打开一次就好。

### KRDC 登不进 macOS 的屏幕共享
macOS 优先提供苹果自己的 DH 认证（类型 30），而 KRDC 不会把用户名传过去（日志：`Authentication: FAILED :: User Name: N/A`）。
换 TigerVNC 1.16，它会同时问用户名和密码：`vncviewer 127.0.0.1::5900`。

## 关于本机

### 处理器名称改不过来（一直是 “2 GHz Quad-Core Intel Core i3”）
RestrictEvents 改的不是显示出来的那行字，而是 AppleSystemInfo 里**按核心数挑的那一项**（4 核是
“Quad-Core Intel Core i5”，8 核是 “8-Core Intel Xeon W”）。SMBIOS 的 `ProcessorType` 留 0 的时候，OpenCore 按 2 GHz
的主频推断成 Core i3，macOS 显示的是 i3 那一项，改过的那一项根本没用上。**解决：** `patch-config.py` 按核心数把
ProcessorType 设成 Core i5（4 核）或 Xeon W（8 核）。

这个是靠调试版 kext 查出来的：`DEBUG_KEXTS=1 EXTRA_BOOT_ARGS="-liludbgall -revdbg liludump=120" opencore/build.sh`，
日志在 macOS 的 `/var/log/Lilu_*.txt`，关键一行是 `chosen Quad-Core Intel Core i5 patch for 4 core CPU`。
日志里那句 `disabling user patcher on request!` 在 macOS 11 以后是正常的，不用管。

## 磁盘

### `mac.qcow2` 只涨不缩
镜像是按需增长的（虚拟大小 160 GB），但没开 discard 的话，macOS 删掉文件腾出来的空间永远不会还给宿主机。
**解决：** 系统盘加 `discard=unmap`，再加 `rotation_rate=1` 让 macOS 把它当成 SSD（`system_profiler SPSerialATADataType`
显示 `TRIM Support: Yes`，不需要 `trimforce`）。实测：开了以后第一次开机，镜像就从 36.9 GiB 缩到了 22.1 GiB
（APFS 挂载时会把空闲空间整体 TRIM 一遍）；写一个 2 GB 的文件涨到 24.1 GiB，删掉后一分钟左右缩回 22.1 GiB。

## 已知限制

- **开机要 2 分钟左右**，大部分时间花在显卡初始化上（驱动会在 “PCI configuration end” 那里停一会儿）。
- **不接显示器就没有桌面。** 驱动要在显卡接口上读到真实的 EDID，WindowServer 才会用这张卡，而它不支持用软件伪造 EDID。
  想无头运行，就在显卡的接口上插一个 HDMI 欺骗器（EDID 模拟器），再用屏幕共享看。
- **屏幕共享只有 20–30 帧左右。** 虚拟机里没有硬件编码器（驱动没提供 NVENC，虚拟机里也没有 VideoToolbox）。
  想要更流畅，只能用 Sunshine/Moonlight 走 CPU 编码，或者买 HDMI 采集卡。
- **直通显卡的 HDMI 声音**在 macOS 里用不了。
- **耗电：** 直通出去的显卡，宿主机管不了它的电源。
- **打字时偶尔闪白屏**（还没解决）。驱动建议的 `-nvrmnoflip` 用不上，因为 `debug.nvaccel_iop_flip` 本来就是 0。
