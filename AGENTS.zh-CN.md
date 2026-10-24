# AGENTS.zh-CN.md：在新机器上搭 macOS + NVIDIA 显卡直通

这份文件是写给 AI 编程助手（Claude Code、Codex 之类）的操作手册，你也可以自己照着做。目标是：在 QEMU/KVM 里跑
macOS Sequoia，把用户的 NVIDIA 显卡直通进去，用 NullMoth 的 Metal 驱动驱动它。

开始之前先读 `README.zh-CN.md` 和 `docs/troubleshooting.zh-CN.md`。中间出了问题，先去踩坑记录里找，别自己瞎试。

[English](AGENTS.md)

## 规矩

1. **宿主机的改动只能通过 `scripts/host.sh` 做。** 它会记录每一项改动，并且能 `rollback`。如果用户的机器需要一项
   这个脚本没有的改动，就把它加进 `host.sh`（要同时写好应用、状态显示和撤销三部分），而不是临时敲几条命令，
   并且告诉用户加了什么。
2. **需要 root 的操作先问用户**，用户想自己敲 `sudo` 就让他自己来。不要把用户的 sudo 密码或 macOS 密码写进任何文件；
   `scripts/guest.sh` 是在运行时从终端读密码的。
3. **卸 NVIDIA 驱动之前先确认没人在用。** 有进程占着显卡时，`host.sh on` 会拒绝执行，把占用的进程列给用户看，
   不要直接杀进程。如果是 KWin/Xwayland，只能让用户注销再登录。
4. **绝对不要直通宿主机唯一的那块显示用的显卡**，也不要为了这个把笔记本的 MUX 切到独显直连模式，否则宿主机会没有屏幕。
5. **`state/` 是私有的。** 里面有磁盘镜像、SSH 密钥和备份，已经被 git 忽略。不要把用户名、密码、序列号、
   家目录路径写进会被提交的文件。
6. 不要让 macOS 自动更新（`scripts/guest.sh prefs` 会关掉）：驱动是按特定 macOS 版本做的。
7. 实话实说：某一步的检查没通过，就停下来，把输出原样告诉用户。

## 第 1 步：检查硬件

运行下面的命令，把结果给用户看。有一条不满足就停下。

```sh
lspci -nnD | grep -iE 'vga|3d|display|audio'          # 找到 NVIDIA 显卡和它的音频功能
for d in /sys/kernel/iommu_groups/*/devices/*; do echo "$(basename $(dirname $(dirname $d))) $(basename $d)"; done \
  | sort -n | grep -E "$(lspci -D -d 10de: | cut -d' ' -f1 | paste -sd'|')"
```

- **IOMMU 要开着**（`/sys/kernel/iommu_groups` 不能是空的）。没开的话，让用户在 BIOS 里打开，并在内核参数里加上
  （AMD 默认就是 `amd_iommu=on`，Intel 要加 `intel_iommu=on`）。
- **显卡所在的 IOMMU 组里只能有显卡和它的音频功能**（桥设备不算）。不是的话就停下：ACS override 补丁不在本项目范围内。
- **显卡要受驱动支持：** 图灵及更新的架构（设备 ID ≥ `1E00`），具体以 NullMoth 驱动 `install.sh` 里的列表为准。
- **至少有一个显示接口接在独显上。** 列出每块显卡的接口：
  `for c in /sys/class/drm/card*-*; do echo "$(basename $(readlink -f $c/device)) ${c##*/} $(cat $c/status)"; done`。
  挂在 NVIDIA 那个 PCI 地址下面的接口，就是以后 macOS 出画面的地方。笔记本上一般是 HDMI，有时还有一个 USB-C；
  带 MUX 的机器还会看到内屏（别用它，见规矩第 4 条）。
- **宿主机桌面能跑在另一块显卡上**（核显，或者另一张独显）。
- **BAR1 大小：** 如果 `/sys/bus/pci/devices/<显卡>/resource1_resize` 存在，说明 BAR 能调整，`BAR1_VM_LOG2_MB=8` 保持不变。
  如果这个文件不存在，而 BAR1（`lspci -vs <显卡>` 里第二个 “Memory at”，带 prefetchable 的那个）本来就是 256M，
  就把 `BAR1_VM_LOG2_MB=` 留空。
- **CPU：** 虚拟机里伪装成 `Skylake-Client`，任何支持 AVX2 的 x86-64 宿主机都行。

## 第 2 步：写 config.env

`cp config.example.env config.env`，和用户一起填：

- `GPU_PCI`、`GPU_AUDIO_PCI`：第 1 步查到的地址，写完整形式（`0000:65:00.0`）。
- `HOST_IGPU_PCI`：跑宿主机桌面的那块显卡的 PCI 地址。`KWIN_DRM_DEVICE`：保持默认，除非已经有一个指向那块卡、
  不带冒号的软链接（`ls -l /dev/dri/`）。
- `VM_CORES` 填 4 或 8（`CPU_NAME` 只在这两个值下生效），`VM_THREADS` 填 2，`VM_RAM_MIB` 不超过宿主机内存的一半。
- `EVDEV_DEVICES`：从 `grep '^N: Name' /proc/bus/input/devices` 里挑键盘和鼠标的名字。触控板别放进去，
  这样宿主机任何时候都至少留一个能用的指针设备。
- `MAC_USER`：用户准备在 macOS 设置助理里建的账户名。
- 不是 KDE Plasma？`host.sh` 的第 1、2 项是 KDE 专用的。先查清楚用户的桌面是什么在占着独显
  （`sudo fuser -v /dev/nvidia* /dev/dri/by-path/pci-<显卡>-*`），再把对应的处理加进 `host.sh`（规矩第 1 条）。

## 第 3 步：下载和生成

```sh
scripts/fetch.sh       # 需要 git curl bsdtar python3 uv qemu-img；从 GitHub 和苹果下载约 1 GB
opencore/build.sh
```

检查：`state/opencore/OpenCore-imacpro.qcow2`、`OpenCore-nvidia.qcow2` 和 `state/recovery.img` 都在。

## 第 4 步：装 macOS（用虚拟显卡）

```sh
sudo scripts/host.sh prepare     # 写好所有宿主机设置（包括 kvm ignore_msrs），显卡还留在宿主机
scripts/boot-macos.sh
```

在 QEMU 窗口里操作（让用户来，或者你用 `scripts/qmp.py key/type/click` 加 `scripts/qmp.py shot` 截图来操作）：
1. OpenCore 菜单里按**空格**，选 **RECOVERY (dmg)**。
2. 磁盘工具 → 把 160 GB 的 “QEMU HARDDISK” 抹成 APFS（名字比如 `macos`）→ 重新安装 macOS Sequoia。
   中途会重启好几次，每次都选 macOS 安装器或者 `macos` 那一项。
3. 如果安装器 20 多分钟不动，QEMU 占满 CPU 但没有磁盘读写，看踩坑记录。
4. 设置助理：建一个名字和 `MAC_USER` 一样的账户。Apple ID 可以跳过。FileVault **关掉**（自动登录要求它关着）。
5. 系统设置 → 通用 → 共享 → 打开**远程登录**（允许远程用户完全磁盘访问）。

然后在宿主机上：

```sh
scripts/guest.sh ssh      # 问一次 macOS 密码，装好 SSH 密钥
scripts/guest.sh prefs    # 关自动更新、关睡眠
```

检查：`scripts/guest.sh shell` 不用密码就能登录，`sw_vers` 显示 15.x。

## 第 5 步：直通显卡并装驱动

```sh
sudo scripts/host.sh on
```

如果它列出了 KWin/Xwayland：设置已经写好了，让用户注销再登录，然后再运行一次。检查：`sudo scripts/host.sh status`
显示两个功能都在 `vfio-pci` 上、BAR1 是 256M；准备启动 QEMU 的那个终端里 `ulimit -l` 是 `unlimited`。

带着显卡启动，但先用会显示选盘界面的那块引导盘（驱动安装程序要能看到显卡）：

```sh
PASSTHROUGH=1 EVDEV=0 OPENCORE_IMG=state/opencore/OpenCore-imacpro.qcow2 scripts/boot-macos.sh
```

直通模式没有 QEMU 窗口。`imacpro` 引导盘会在显卡的接口上显示选盘界面，选 macOS 那块盘
（用户没法操作的话用 `scripts/qmp.py key right ret`）。等 SSH 能连上（2 分钟左右）：

```sh
scripts/guest.sh driver   # 先预检再安装，会问 macOS 密码
```

检查：安装前 `ioreg` 能看到 `10de`；安装最后输出 “Done. Reboot now”。然后关掉 macOS
（`scripts/guest.sh shell` → `sudo shutdown -h now`）。

## 第 6 步：正式直通启动

让用户在独显的接口上接一台显示器（或者插一个 HDMI 欺骗器，见已知限制）。

```sh
PASSTHROUGH=1 scripts/boot-macos.sh
```

OpenCore 画面和开机跑码会出现在那台显示器上；`nvidia` 引导盘不显示选盘界面，直接启动。开机 20 秒后
`EVDEV_DEVICES` 里的键鼠会被虚拟机接管（同时按左右 Shift 切换）。大约 2 分钟后显示器上出现 macOS 登录界面。
SSH 进去检查：

```sh
scripts/guest.sh shell
kmutil showloaded --list-only | grep nullmoth                       # 4 个 kext
system_profiler SPDisplaysDataType | sed -n '/NVIDIA/,$p'           # Metal 3，并且有 Displays: 一节
ls -t /Library/Logs/DiagnosticReports/ | head                       # 没有新的 WindowServer-*.ips
```

然后：

```sh
scripts/guest.sh autologin       # 问密码，写入 /etc/kcpassword
scripts/guest.sh deskflow        # 用户要在“隐私与安全性 → 辅助功能”里允许 Deskflow
scripts/guest.sh screensharing   # 用户要在系统设置里把屏幕共享关掉再打开一次
```

在宿主机上打开 Deskflow（`host.sh on` 已经配好了）：用户点 Start，并允许 KDE 弹出的输入捕获请求。鼠标从宿主机屏幕
左右边缘移出去应该就进 macOS 了。按显示器实际摆放的位置改 `deskflow/server.conf`（改完在 Deskflow 里 Stop → Start）。

## 第 7 步：验收，交给用户

- 什么都不碰，重启一次 macOS：应该自己进桌面，并且 Deskflow 自动连上。
- `vncviewer 127.0.0.1::5900` 能看到桌面（用 macOS 用户名和密码登录）。
- “关于本机”里能看到显卡，设了 `CPU_NAME` 的话处理器名也对。
- 关掉 macOS，`sudo scripts/host.sh off`，确认宿主机上 `nvidia-smi` 又能用了。
- 给用户看一遍 `sudo scripts/host.sh status`，提醒他有 `rollback`。

## 以后要改什么

- CPU 核心数：改 `VM_CORES`（4 或 8 才能保留处理器名），再跑 `opencore/build.sh`。
- 换 `CPU_NAME`：跑 `opencore/build.sh`，重启 macOS。
- 排查开机问题：`EXTRA_BOOT_ARGS="debug=0x100" opencore/build.sh`；要调试版 kext 就加 `DEBUG_KEXTS=1`。
- 升级驱动或 kext：改 `scripts/fetch.sh` 里的地址和 SHA-256，校验这一步绝不能省。
