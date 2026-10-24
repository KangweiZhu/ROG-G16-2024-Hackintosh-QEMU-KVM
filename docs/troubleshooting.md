# Troubleshooting

Every problem below was hit while building this setup (Ryzen AI 9 HX 370 + RTX 4060 Laptop, Arch Linux, KDE Plasma 6.8 Wayland, QEMU 11.1, macOS 15.8.1, NullMoth driver 2.5.3). Each entry: what you see, why, and what the scripts do about it.

[中文](troubleshooting.zh-CN.md)

## Installing macOS

### macOS panics or reboots early, host log full of `kvm: ignored rdmsr`
macOS reads MSRs KVM doesn't emulate. **Fix:** `options kvm ignore_msrs=1` (`/etc/modprobe.d/kvm.conf`, item 4 of `host.sh`).

### No `dmg2img`, QEMU has no LZFSE support: how to boot `BaseSystem.dmg`?
OpenCore can boot the dmg directly from any FAT volume that has `com.apple.recovery.boot/`. `scripts/mkrecovery.py` builds such a FAT32 image with pyfatfs (no root, no loop devices). Attach it read-only with `snapshot=on` (`readonly=on` fails on a SATA device with "Block node is read-only").

### The recovery entry is missing from the OpenCore picker
OSX-KVM sets `HideAuxiliary`: press **Space** in the picker to show `RECOVERY (dmg)`.

### Installer stuck for 20+ minutes, QEMU at 800 % CPU, no disk I/O
Seven vCPUs spun at one kernel address and vCPU 0 sat in UEFI runtime code: most likely a kernel panic whose report was being written to NVRAM (the same pattern as the next entry, where the panic report could be read). The cause during installation was not found; after a QMP `system_reset` (`{"execute":"system_reset"}` on `state/qmp.sock`) the installer resumed and finished.

### Kernel panic in `AppleIntelMCEReporter` after switching SMBIOS to `iMacPro1,1`
`com.apple.driver.AppleIntelMCEReporter : AppleIntelMCE::Controller::~Controller + 0x8c`, page fault at `CR2 0x8`. The MCE reporter matches iMacPro/MacPro board IDs and crashes in a VM. OSX-KVM ships `MCEReporterDisabler.kext` but its config.plist points at `AppleMCEReporterDisabler.kext`, so it never loaded (iMac19,1 doesn't need it). **Fix:** `opencore/patch-config.py` corrects the path.

**How to read a panic you cannot see:** boot the old disk (`OPENCORE_IMG=state/OSX-KVM/OpenCore/OpenCore.qcow2 scripts/boot-macos.sh`), then read `/Library/Logs/DiagnosticReports/Kernel-*.panic` over SSH. Or rebuild with `EXTRA_BOOT_ARGS="-v debug=0x100" opencore/build.sh` so a panic stays on screen.

## Handing the GPU to the VM

### NullMoth `install.sh`: `STOP: no NVIDIA GPU found on PCI`
The installer checks for the card. Pass the GPU through first (`PASSTHROUGH=1`), then install, still using the `imacpro` OpenCore disk.

### `host.sh on` refuses: KWin/Xwayland still use the GPU
On KDE Plasma (Wayland) KWin opens every DRM device, and on many laptops the HDMI port is wired to the dGPU. Unloading `nvidia` while KWin holds it can hang or kill the session. Two settings are needed (items 1 and 2), then log out and back in:
- `KWIN_DRM_DEVICES=<iGPU card>`: KWin drives only the iGPU. The variable is `:`-separated, so `/dev/dri/by-path/pci-0000:…` cannot be used; `host.sh` creates a udev symlink without colons if needed.
- `__EGL_VENDOR_LIBRARY_FILENAMES=…/50_mesa.json` for the KWin service only. With just the first setting KWin still loaded NVIDIA's EGL (glvnd tries `10_nvidia.json` first) and kept a 7 MiB context on the dGPU (`nvidia-smi` shows `kwin_wayland C+G`).

Cost: while this is set the host desktop cannot use outputs wired to the dGPU.

### QEMU: `vfio … Cannot allocate memory` / `ulimit -l` is still 8192 after adding `limits.d`
VFIO pins all guest RAM. Desktop sessions are started by the systemd user manager, which does not go through `pam_limits`, and with `loginctl enable-linger` the user manager survives logouts. **Fix:** `LimitMEMLOCK=infinity` in a `user@.service` drop-in (item 3, effective after reboot). Until then `host.sh on` raises the limit of the terminal that ran it with `prlimit`.

`nvidia-powerd` also holds the device: `host.sh` stops it.

## GPU passthrough boot

### macOS boots but does not see the GPU; QMP `query-pci` shows its BARs at address `-1`
The RTX 4060 Laptop exposes an 8 GiB BAR1 (Resizable BAR). OVMF's default 64-bit MMIO window can't place it and leaves every BAR unassigned. **Fix:** `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536`.

### GPU behind a `pcie-root-port`: macOS shows the bridge but nothing behind it
`ioreg` shows `IOPCIHotPlug = Yes`, `IOPCISlotDevicePresent = No`, `IOPCIExpressSlotStatus = 0` and a link status without DLLLA: macOS treats the slot as empty and never scans it. `hotplug=off` doesn't help. **Fix:** put the GPU directly on `pcie.0` (as in OSX-KVM's passthrough notes).

### QEMU aborts: `KVM_SET_USER_MEMORY_REGION failed, slot=12, start=0x8209700000000000, size=0x200000000: Invalid argument`
With the GPU on the root bus, the guest writes a 32-bit address into the upper half of the 8 GiB BAR1 while reconfiguring it; KVM rejects the mapping and QEMU exits. The NullMoth README also warns that large firmware BARs can stop PCI configuration. **Fix:** shrink BAR1 on the host to 256 MiB before handing the GPU over (`resource1_resize`, item 6). VRAM stays 8 GB; the driver logs `BAR1 256 MB, VRAM 8188 MB`. `host.sh off` restores the original size.

### WindowServer crash loop: `CoreDisplay_CreateDisplayForCGXDisplayDevice` assertion
Two different causes produced the same crash:
1. **Two framebuffers.** With `vmware-svga` as the boot display, macOS has the firmware framebuffer (`IONDRVSupport`, `.Display_boot`, index 0) and `NVRMFB`. The NullMoth README says to exclude IONDRVSupport with OpenCore's `Kernel → Block`, but that only works for kexts in the Boot KC; IONDRVSupport loads from the System KC. **Fix:** no emulated display in passthrough mode (`-vga none -display none`). The GPU's own GOP then shows OVMF/OpenCore on its port.
2. **"Headless" verdict.** Log: `NVMTLDriver: headless GPU: no device for WindowServer`. The driver waits 60 s for a display head, then decides the GPU is a render-only card (laptops with the panel on the iGPU). In the VM the GPU needs ~100 s to light its port, so the deadline passes first. **Fix:** boot-arg `-nvaccelnoheadless`.

### HDMI has signal but the screen stays black
Same as above: check `/Library/Logs/DiagnosticReports/WindowServer-*.ips` and `log show --predicate 'process == "WindowServer"'`.

### Boot reports "not supported" after setting QEMU `model-id=<your CPU>`
Changing the CPUID brand string breaks the boot. Don't. Use `CPU_NAME` (RestrictEvents) for the name in About This Mac.

## Input

### The OpenCore picker waits forever and defaults to "EFI"
"EFI" is OpenCore's own disk. In passthrough mode there's no window to type into. **Fix:** the `nvidia` disk scans only APFS on SATA and skips the picker (`ScanPolicy 0x10103`, `ShowPicker false`); use the `imacpro` disk when you need the picker (recovery).

### The passthrough boot stops at the picker anyway
With the evdev fallback the keyboard belongs to the VM from power-on, so whatever the user types at that moment
(typically the Shift+Shift toggle) reaches OpenCore, which brings the picker up even with `ShowPicker false`.
**Fix:** `PollAppleHotKeys false` on the `nvidia` disk, and `boot-macos.sh` attaches evdev 20 s later when that disk
is used. Tested by sending Shift/Esc/Enter/Space over QMP for the first 14 s of a boot.

### Stuck at the login window: no keyboard/mouse
Deskflow runs only after login. **Fix:** automatic login (`scripts/guest.sh autologin`, FileVault must be off), plus the evdev fallback.

### evdev fallback: the mouse doesn't move in the picker
The mouse is relative and `usb-tablet` takes only absolute events, so a `usb-mouse` is needed. Hot-plugged after power-on, the firmware never enumerates it. **Fix:** `boot-macos.sh` adds `usb-mouse` at startup.

### evdev fallback: Shift+Shift works on one keyboard only
`input-linux` detects the toggle per device. **Fix:** every device gets `grab_all=on` and the toggle keys (`scripts/qmp.py input-attach`). Default `ctrl-ctrl` doesn't work on keyboards without a right Ctrl (HHKB), hence `shift-shift`.

### Deskflow 1.27: `unknown computer name "linux"` / "Your server config has a screen section…"
Since 1.27 the screen list lives in the settings file as `[computer_<name>]` groups; a `section: screens` in the server config is ignored. See `deskflow/linux-Deskflow.conf.in`.

### Deskflow connected, but the cursor won't cross the top edge (KDE Wayland)
The input-capture barrier on the top edge never fired here; left/right edges work. `deskflow/server.conf` links all three.

### Deskflow on macOS stops working; its window says "Deskflow is not running"
Seen once, ~10 s after login: `uncaught exception ... event queue`, client exited with code 6, and the Deskflow window
does not restart it. **Fix:** the login agent installed by `scripts/guest.sh deskflow` is also a watchdog that
restarts the app every 30 s if no client process is running.

### Deskflow on macOS doesn't connect after login
An "check for updates?" dialog blocks the client from starting. `enableUpdateCheck=false` in both settings files.

### Screen Sharing (VNC) connects but the picture is black
`ScreensharingAgent: Cannot get shareable content` / `replayd: TCC Disallow`: Screen Sharing enabled from the command line gets no screen-capture permission. Switch it off and on once in System Settings > General > Sharing.

### KRDC can't log in to macOS Screen Sharing
macOS offers Apple's DH authentication (type 30) first; KRDC doesn't send the user name (`Authentication: FAILED :: User Name: N/A`). TigerVNC 1.16 asks for user name and password: `vncviewer 127.0.0.1::5900`.

## About This Mac

### The processor name doesn't change ("2 GHz Quad-Core Intel Core i3")
RestrictEvents rewrites the AppleSystemInfo string macOS would show **for this core count** ("Quad-Core Intel Core i5" for 4 cores, "8-Core Intel Xeon W" for 8). With SMBIOS `ProcessorType` = 0 OpenCore derives "Core i3" from the 2 GHz clock, so the rewritten string is never shown. **Fix:** `patch-config.py` sets ProcessorType to Core i5 (4 cores) or Xeon W (8 cores). Found with the DEBUG kexts: `DEBUG_KEXTS=1 EXTRA_BOOT_ARGS="-liludbgall -revdbg liludump=120" opencore/build.sh`, log in the guest's `/var/log/Lilu_*.txt` (`chosen Quad-Core Intel Core i5 patch for 4 core CPU`). `disabling user patcher on request!` in that log is normal on macOS 11+.

## Known limitations

- **Boot takes ~2 minutes**, mostly the GPU initialising (the driver pauses at "PCI configuration end").
- **No monitor = no desktop.** The driver needs a real EDID on the GPU's port before WindowServer will use it, and it has no software EDID override. For headless use plug an HDMI dummy plug (EDID emulator) into the GPU's port and use Screen Sharing.
- **Screen Sharing is ~20–30 fps.** There is no hardware encoder (no NVENC in the driver, no VideoToolbox in the VM). Sunshine/Moonlight with CPU encoding or an HDMI capture card are the alternatives.
- **HDMI audio** of the passed-through GPU is not available in macOS.
- **Battery:** the passed-through GPU is never power-managed by the host.
- **Occasional white flash while typing** (open). The driver's `-nvrmnoflip` doesn't apply (`debug.nvaccel_iop_flip` is already 0).
