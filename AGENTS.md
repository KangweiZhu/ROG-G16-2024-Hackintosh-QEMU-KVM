# AGENTS.md: setting up macOS + NVIDIA GPU passthrough on a new machine

You are a coding agent helping a user run macOS Sequoia in QEMU/KVM with their NVIDIA GPU passed through and
accelerated by the NullMoth Metal driver. This file is your playbook. Read `README.md` and
`docs/troubleshooting.md` first; when something fails, look there before improvising.

[中文](AGENTS.zh-CN.md)

## Ground rules

1. **Host changes go through `scripts/host.sh` only.** It records everything it changes and has `rollback`. If the
   user's machine needs a host change this script doesn't make, add it to `host.sh` (apply + status + rollback)
   instead of running one-off commands, and tell the user.
2. **Ask before anything that needs root**, and let the user run `sudo` themselves if they prefer. Never store the
   user's sudo or macOS password in a file; `scripts/guest.sh` reads it from the terminal.
3. **Check before unloading the NVIDIA driver.** `host.sh on` refuses while processes hold the GPU; show the user
   that list rather than killing processes. If it is KWin/Xwayland, the user must log out and back in.
4. **Never pass through a GPU that drives the host's only display**, and never switch the laptop MUX to
   dGPU-only mode for this: the host would lose its screen.
5. **Keep `state/` private.** It holds the disk image, SSH key and backups and is git-ignored. Don't put user
   names, passwords, serial numbers or home paths into tracked files.
6. Don't let macOS update itself (`scripts/guest.sh prefs`): the driver is built for specific macOS versions.
7. Report honestly: if a step's check fails, stop and say so with the output.

## Step 1: check the hardware

Run these and show the user the results. Stop if a requirement isn't met.

```sh
lspci -nnD | grep -iE 'vga|3d|display|audio'          # find the NVIDIA GPU and its audio function
for d in /sys/kernel/iommu_groups/*/devices/*; do echo "$(basename $(dirname $(dirname $d))) $(basename $d)"; done \
  | sort -n | grep -E "$(lspci -D -d 10de: | cut -d' ' -f1 | paste -sd'|')"
```

- **IOMMU on** (`/sys/kernel/iommu_groups` not empty). Otherwise the user enables it in firmware and on the kernel
  command line (`amd_iommu=on` is default on AMD, `intel_iommu=on` on Intel).
- **The GPU's IOMMU group contains only the GPU and its audio function** (bridges excluded). Otherwise stop: ACS
  override patches are out of scope.
- **Supported GPU:** NVIDIA Turing or newer (device ID ≥ `1E00`); check the NullMoth driver's `install.sh` list.
- **A display output wired to the dGPU.** List each GPU's connectors:
  `for c in /sys/class/drm/card*-*; do echo "$(basename $(readlink -f $c/device)) ${c##*/} $(cat $c/status)"; done`.
  Connectors under the NVIDIA PCI address are where macOS will show its picture. On laptops this is usually HDMI
  and/or one USB-C port; with a MUX the internal panel may also appear (don't use it, rule 4).
- **The host desktop runs on another GPU** (an iGPU, or a second card).
- **BAR1 size:** `cat /sys/bus/pci/devices/<GPU>/resource1_resize` exists → the BAR can be resized; keep
  `BAR1_VM_LOG2_MB=8`. If the file doesn't exist and BAR1 (`lspci -vs <GPU>`, second "Memory at", prefetchable)
  is already 256M, set `BAR1_VM_LOG2_MB=` (empty).
- **macOS needs an Intel-looking CPU:** the VM presents `Skylake-Client`. Any x86-64 host with AVX2 works.

## Step 2: write config.env

`cp config.example.env config.env` and fill it in with the user:

- `GPU_PCI`, `GPU_AUDIO_PCI`: from step 1 (full form `0000:65:00.0`).
- `HOST_IGPU_PCI`: the PCI address of the GPU that runs the host desktop. `KWIN_DRM_DEVICE`: keep the default
  unless a colon-free symlink to that card already exists (`ls -l /dev/dri/`).
- `VM_CORES` 4 or 8 (`CPU_NAME` only works with these), `VM_THREADS` 2, `VM_RAM_MIB` ≤ half of host RAM.
- `EVDEV_DEVICES`: keyboard(s) and mouse names from `grep '^N: Name' /proc/bus/input/devices`. Leave the touchpad
  out so the host always keeps one pointer.
- `MAC_USER`: the account name the user will create in macOS Setup Assistant.
- Not KDE Plasma? Items 1/2 of `host.sh` are KDE-specific. Find out what keeps the dGPU busy on their desktop
  (`sudo fuser -v /dev/nvidia* /dev/dri/by-path/pci-<GPU>-*`) and add the equivalent to `host.sh` (rule 1).

## Step 3: download and build

```sh
scripts/fetch.sh       # needs: git curl bsdtar python3 uv qemu-img; ~1 GB download from GitHub and Apple
opencore/build.sh
```

Check: `state/opencore/OpenCore-imacpro.qcow2` and `OpenCore-nvidia.qcow2` exist, `state/recovery.img` exists.

## Step 4: install macOS (emulated display)

```sh
sudo scripts/host.sh prepare     # all host settings incl. kvm ignore_msrs, GPU stays on the host
scripts/boot-macos.sh
```

In the QEMU window (the user does this, or you drive it with `scripts/qmp.py key/type/click` and
`scripts/qmp.py shot` screenshots):
1. OpenCore picker: press **Space**, choose **RECOVERY (dmg)**.
2. Disk Utility → erase the 160 GB "QEMU HARDDISK" as APFS (name e.g. `macos`) → Reinstall macOS Sequoia.
   It reboots several times; choose the macOS installer / `macos` entry each time.
3. If the installer sits for 20+ minutes with QEMU at full CPU and no disk I/O, see troubleshooting.
4. Setup Assistant: create the account named `MAC_USER`. Skip Apple ID if the user wants. FileVault **off**
   (automatic login needs it off).
5. System Settings > General > Sharing > **Remote Login** on (allow full disk access for remote users).

Then from the host:

```sh
scripts/guest.sh ssh      # asks the macOS password once to install the SSH key
scripts/guest.sh prefs    # no automatic updates, no sleep
```

Check: `scripts/guest.sh shell` logs in without a password; `sw_vers` shows 15.x.

## Step 5: pass the GPU through and install the driver

```sh
sudo scripts/host.sh on
```

If it lists KWin/Xwayland: the settings are now written; the user logs out and back in, then runs it again.
Check: `sudo scripts/host.sh status` shows both functions on `vfio-pci` and BAR1 at 256M; `ulimit -l` in the
terminal that will start QEMU is `unlimited`.

Boot with the GPU but still on the emulated display (the driver's installer needs to see the card):

```sh
PASSTHROUGH=1 EVDEV=0 OPENCORE_IMG=state/opencore/OpenCore-imacpro.qcow2 scripts/boot-macos.sh
```

In passthrough mode there is no QEMU window. The `imacpro` disk shows the picker on the GPU's port; select the
macOS disk (`scripts/qmp.py key right ret` if the user can't). Wait for SSH (~2 min):

```sh
scripts/guest.sh driver   # CHECK run, then install; asks the macOS password
```

Check: `ioreg` sees `10de` before the install; the install ends with "Done. Reboot now". Shut the guest down
(`scripts/guest.sh shell` → `sudo shutdown -h now`).

## Step 6: the real passthrough boot

The user connects a monitor to the dGPU's port (or an HDMI dummy plug, see limitations).

```sh
PASSTHROUGH=1 scripts/boot-macos.sh
```

The OpenCore screen and verbose text appear on that monitor; the `nvidia` disk boots without a picker. 20 s after
start the keyboard and mouse from `EVDEV_DEVICES` go to the VM (both Shift keys toggle). After ~2 minutes the macOS
login window appears on the monitor. Check over SSH:

```sh
scripts/guest.sh shell
kmutil showloaded --list-only | grep nullmoth                       # 4 kexts
system_profiler SPDisplaysDataType | sed -n '/NVIDIA/,$p'           # Metal 3, a Displays: section
ls -t /Library/Logs/DiagnosticReports/ | head                       # no fresh WindowServer-*.ips
```

Then:

```sh
scripts/guest.sh autologin       # asks the password, writes /etc/kcpassword
scripts/guest.sh deskflow        # user allows Deskflow under Privacy & Security > Accessibility
scripts/guest.sh screensharing   # user toggles Screen Sharing off/on once in System Settings
```

On the host, start Deskflow (it was configured by `host.sh on`): the user clicks Start and allows the KDE
input-capture prompt. Moving the pointer off the left/right edge of the host screen should enter macOS. Adjust
`deskflow/server.conf` to match where the monitor physically sits (Stop → Start to reload).

## Step 7: verify and hand over

- Reboot the guest without touching anything: it should reach the desktop with Deskflow connected.
- `vncviewer 127.0.0.1::5900` shows the desktop (user name + password).
- About This Mac shows the GPU, and `CPU_NAME` if set.
- Shut the guest down, `sudo scripts/host.sh off`, check `nvidia-smi` works on the host again.
- Show the user `sudo scripts/host.sh status` and remind them of `rollback`.

## Changing things later

- CPU cores: change `VM_CORES` (4 or 8 keeps the CPU name), then `opencore/build.sh`.
- Another `CPU_NAME`: `opencore/build.sh`, reboot the guest.
- Debugging a boot: `EXTRA_BOOT_ARGS="debug=0x100" opencore/build.sh`; DEBUG kexts: `DEBUG_KEXTS=1`.
- Newer driver/kext versions: update the URL and SHA-256 in `scripts/fetch.sh`, never skip the checksum.
