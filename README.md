<div align="center">

# macOS on KVM with a passed-through NVIDIA RTX GPU

**Metal-accelerated macOS Sequoia in a QEMU/KVM virtual machine on the 2024 ASUS ROG Zephyrus G16 (GA605W):<br>
AMD Ryzen AI 9 HX 370 + NVIDIA RTX 4060 Laptop, Arch Linux host.**

[![macOS](https://img.shields.io/badge/macOS-15.8.1_Sequoia-black?logo=apple)](#tested-on)
[![GPU](https://img.shields.io/badge/GPU-RTX_4060_Laptop-76B900?logo=nvidia&logoColor=white)](#what-works)
[![Metal](https://img.shields.io/badge/Metal-3-blue)](#what-works)
[![QEMU/KVM](https://img.shields.io/badge/QEMU%2FKVM-11.1-orange?logo=qemu&logoColor=white)](#tested-on)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

[Quick start](#quick-start) · [How it works](#how-it-works) · [Troubleshooting](docs/troubleshooting.md) · [AGENTS.md](AGENTS.md) · [中文](README.zh-CN.md)

<br>

<img src="docs/images/about-this-mac.png" height="420" alt="About This Mac: AMD Ryzen AI 9 HX 370, NVIDIA GeForce RTX 4060 Laptop GPU 8 GB, macOS Sequoia 15.8.1">
&nbsp;&nbsp;
<img src="docs/images/system-information-gpu.png" height="420" alt="System Information, Graphics/Displays: NVIDIA GeForce RTX 4060 Laptop GPU, 8 GB, Metal 3, 1920x1080 at 144 Hz">

<sub>The GPU drives the macOS desktop at 1080p 144 Hz through its own HDMI port.</sub>

</div>

<!-- Demo video: upload the .mp4 by dragging it into a GitHub issue/PR comment, then paste the
     https://github.com/user-attachments/assets/... link on its own line here. -->

The VM gets the laptop's RTX 4060 through VFIO, and [NullMoth's open-source NVIDIA Metal driver](https://github.com/nullmoth/nvidia-macos-driver)
runs it inside macOS: the desktop is composited by the GPU and appears on the GPU's own HDMI port, while the host keeps
the iGPU and the laptop panel. Keyboard and mouse move between Linux and macOS with Deskflow.

- **One script for the host**, with `status` and `rollback`: nothing is changed that you can't list or undo.
- **Pinned, checksummed downloads**; nothing third-party is redistributed.
- **No stored passwords**; private data stays in the git-ignored `state/`.
- **[`AGENTS.md`](AGENTS.md)** walks an AI coding agent (or you) through the whole setup on a new machine, with a check after every step.

## Who this is for

This is a write-up and a set of scripts for **one specific machine**: the **2024 ASUS ROG Zephyrus G16, AMD
version (GA605W)**, with a Ryzen AI 9 HX 370 (Radeon 890M iGPU) and an RTX 4060 Laptop GPU, running **Arch Linux**
with KDE Plasma. Everything was built and tested there.

It is **not a bare-metal Hackintosh**: Linux stays the host OS and macOS runs as a QEMU/KVM virtual machine that
borrows the RTX 4060 while it runs (VFIO passthrough). On other hardware the same approach should work if the
requirements in [AGENTS.md step 1](AGENTS.md#step-1-check-the-hardware) hold, but expect to adapt PCI addresses,
ports and desktop-specific settings.

## What works

|             |                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------ |
| GPU         | RTX 4060 Laptop (AD107, `10de:28e0`), 8 GB, Metal 3, desktop accelerated by the GPU                              |
| Display     | the GPU's HDMI port, 1080p @ 144 Hz; OpenCore picker and verbose boot also show there (GPU GOP)                    |
| Boot        | unattended: no picker, automatic login, ~2 min (the GPU takes ~100 s to come up)                                   |
| Input       | Deskflow (move the pointer off the laptop screen's edge into macOS) + evdev passthrough fallback (both Shift keys) |
| Remote view | macOS Screen Sharing in a Linux window (TigerVNC), ~20–30 fps                                                     |
| Host        | the laptop keeps its iGPU and internal panel; the GPU returns to the NVIDIA driver with `host.sh off`            |

Not working / limits: HDMI audio, sleep/wake, headless use without a monitor or HDMI dummy plug, high-fps remote
view. See [docs/troubleshooting.md](docs/troubleshooting.md#known-limitations).

## Tested on

|         |                                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------ |
| Machine | ASUS ROG Zephyrus G16 (GA605WV), Ryzen AI 9 HX 370 + Radeon 890M + RTX 4060 Laptop, MUX in Hybrid mode |
| Host    | Arch Linux, kernel 7.2, QEMU 11.1, KDE Plasma 6.8 (Wayland), nvidia-open 615.78                        |
| Guest   | macOS 15.8.1 (24H32), SMBIOS iMacPro1,1, OpenCore from OSX-KVM, NullMoth driver 2.5.3                  |

Other Turing-or-newer NVIDIA GPUs supported by the driver should work the same way. What has to be true of your
machine: the GPU sits alone in its IOMMU group, at least one display port is wired to the dGPU, and the host
desktop can run on another GPU. `AGENTS.md` step 1 shows how to check.

## How it works

```
 Linux host (iGPU drives the laptop panel and desktop)              macOS guest (QEMU/KVM, q35, OVMF)
 ───────────────────────────────────────────────────                ───────────────────────────────────────────
 scripts/host.sh on                                                 OpenCore (OSX-KVM image, patched):
   KWin → iGPU only, no NVIDIA EGL                                    iMacPro1,1, csr 0x0A43, SecureBootModel off,
   nvidia unloaded, GPU + HDMI audio → vfio-pci                       Lilu + AMFIPass + RestrictEvents,
   BAR1 8 GiB → 256 MiB, memlock unlimited                            NullMoth boot-args, no picker
 scripts/boot-macos.sh  PASSTHROUGH=1  ──── vfio-pci on pcie.0 ───▶ NullMoth driver: NVRM (open GPU kernel modules
   -vga none, big 64-bit MMIO window                                  + GSP) → NVRMFB framebuffer → NVAccel → Metal
 Deskflow server (127.0.0.1:24800) ◀── user net 10.0.2.2 ───────── Deskflow client (starts at auto-login)
 vncviewer 127.0.0.1::5900  ◀───────── hostfwd ──────────────────── Screen Sharing
                                                   GPU HDMI port ──▶ external monitor
```

## Quick start

Follow [`AGENTS.md`](AGENTS.md) for the full procedure with checks at every step. In short:

```sh
cp config.example.env config.env    # PCI addresses, iGPU, input devices, VM size, macOS user
scripts/fetch.sh                    # OSX-KVM, kexts, driver, Deskflow (pinned + SHA-256), recovery, empty disk
opencore/build.sh                   # state/opencore/OpenCore-{imacpro,nvidia}.qcow2

sudo scripts/host.sh prepare        # host settings (kvm ignore_msrs, KWin, memlock, Deskflow); GPU stays on the host
scripts/boot-macos.sh               # 1. install macOS in a QEMU window (Space in the picker → RECOVERY)
                                    #    enable Remote Login in the guest, then:
scripts/guest.sh ssh && scripts/guest.sh prefs

sudo scripts/host.sh on             # 2. hand the GPU over (log out/in once if KWin holds it)
PASSTHROUGH=1 OPENCORE_IMG=state/opencore/OpenCore-imacpro.qcow2 scripts/boot-macos.sh
scripts/guest.sh driver             #    install the NullMoth driver, shut the guest down

PASSTHROUGH=1 scripts/boot-macos.sh # 3. real passthrough boot: picture on the GPU's port
scripts/guest.sh autologin && scripts/guest.sh deskflow && scripts/guest.sh screensharing
```

## Daily use

```sh
sudo scripts/host.sh on                 # GPU → VM; the first time after logging in it asks you to log out and in once
PASSTHROUGH=1 scripts/boot-macos.sh     # after 20 s keyboard/mouse go to the VM: press both Shift keys to take them back
                                        # after ~2 min macOS is logged in and Deskflow connects
vncviewer 127.0.0.1::5900               # optional: macOS in a window on the Linux desktop
scripts/guest.sh shell                  # SSH into the guest
# shut macOS down, then:
sudo scripts/host.sh off                # GPU → NVIDIA driver, BAR1 restored; HDMI is the host's again from the next login
```

`EVDEV=0` skips the evdev fallback. `OPENCORE_IMG=state/opencore/OpenCore-imacpro.qcow2` gives you the boot
picker (recovery). Without `PASSTHROUGH=1` the VM runs on the emulated display in a QEMU window.

## Host changes

`sudo scripts/host.sh status` lists them, `prepare` applies the configuration, `on` also hands the GPU over, `rollback` undoes all of them.

| # | Change                                                                                                      | Why                                                                 |
| - | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1 | `~/.config/environment.d/90-macos-vm-kwin.conf`: `KWIN_DRM_DEVICES=<iGPU>` (+ a udev symlink if needed) | KWin otherwise keeps the dGPU open                                  |
| 2 | KWin service drop-in: Mesa-only EGL                                                                         | glvnd loads NVIDIA's EGL first and KWin keeps a context on the dGPU |
| 3 | `user@.service` drop-in: `LimitMEMLOCK=infinity`                                                        | VFIO pins guest RAM; `limits.d` doesn't reach desktop sessions    |
| 4 | `/etc/modprobe.d/kvm.conf`: `ignore_msrs=1`                                                             | macOS reads MSRs KVM doesn't emulate                                |
| 5 | runtime: GPU → `vfio-pci`, nvidia modules unloaded                                                       | passthrough                                                         |
| 6 | runtime: BAR1 → 256 MiB                                                                                    | a full-VRAM BAR1 crashes QEMU during guest PCI setup                |
| 7 | `pacman -S deskflow`                                                                                      | keyboard/mouse sharing                                              |
| 8 | `~/.config/Deskflow/Deskflow.conf`                                                                        | Deskflow server, 127.0.0.1 only                                     |

1 and 2 exist only while the VM is in use: `on` writes them, `off` removes them. KWin reads them at login, so the first
`on` of a session asks for one log out/in, and after `off` the host desktop gets the dGPU's ports (HDMI) back at the
next login. 8 applies at the next login; 3 and 4 at the next boot (`on` raises memlock for the current terminal meanwhile).

## Layout

```
config.example.env    machine settings (copy to config.env, git-ignored)
scripts/
  fetch.sh            downloads (pinned, SHA-256), recovery image, empty disk
  boot-macos.sh       start the VM (emulated display or PASSTHROUGH=1)
  host.sh             all host changes: status / on / off / rollback
  guest.sh            configure macOS over SSH: ssh, prefs, autologin, screensharing, driver, deskflow, shell
  qmp.py              QMP: keys, screenshots, power, evdev attach/detach
  mkrecovery.py       FAT32 image with BaseSystem.dmg for OpenCore
  lib.sh              shared paths and config loading
opencore/
  build.sh            build the two OpenCore disks from OSX-KVM's image
  patch-config.py     the config.plist changes, each with its reason
  esp.py              read/write the ESP inside a disk image (pyfatfs, no root)
deskflow/             server layout and settings templates
docs/troubleshooting.md  every problem hit along the way: symptom, cause, fix
state/                (git-ignored) disks, firmware vars, downloads, SSH key, host backups, QMP socket
```

Host tools: `qemu` (with `qemu-img`), `uv` (runs the pyfatfs scripts), `git`, `curl`, `bsdtar`, `python3`, `tigervnc`.

## Credits and licences

- [NullMoth nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver): the Metal driver this is all about (see its licence).
- [OSX-KVM](https://github.com/kholia/OSX-KVM): OVMF, the OpenCore image and `fetch-macOS-v2.py`, fetched at a pinned commit.
- [acidanthera](https://github.com/acidanthera): OpenCore, Lilu, RestrictEvents. [dhinakg/AMFIPass](https://github.com/dortania/OpenCore-Legacy-Patcher) via OpenCore Legacy Patcher.
- [Deskflow](https://github.com/deskflow/deskflow).

Nothing from these projects is redistributed here; `scripts/fetch.sh` downloads them. The scripts in this
repository are MIT-licensed ([LICENSE](LICENSE)).

Apple's macOS licence permits running macOS only on Apple hardware. This repository is for research and
education; you are responsible for complying with the licences that apply to you.
