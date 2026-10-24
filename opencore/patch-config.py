#!/usr/bin/env python3
"""Turn OSX-KVM's OpenCore config.plist into one that loads the NullMoth NVIDIA driver.

  patch-config.py <in.plist> <out.plist> imacpro|nvidia

  imacpro  for the emulated display (installing macOS, recovery, first driver install): shows the boot picker
  nvidia   for GPU passthrough: verbose boot, no picker, settings the driver needs at runtime

Environment (exported by build.sh from config.env): CPU_NAME, VM_CORES, EXTRA_BOOT_ARGS.
Follows the NullMoth README section "Wiring into an existing OpenCore setup".
"""
import os, plistlib, sys

src, dst, variant = sys.argv[1:]
c = plistlib.load(open(src, "rb"))
NV = "7C436110-AB2A-4BBB-A880-FE41995C9F82"   # Apple NVRAM GUID
RE = "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"   # OpenCore vendor GUID (RestrictEvents reads revcpuname here)
cpu_name = os.environ.get("CPU_NAME", "").strip()
cores = int(os.environ.get("VM_CORES", "4"))

# RestrictEvents renames the CPU by rewriting the one AppleSystemInfo string that macOS would show for this core
# count ("Quad-Core Intel Core i5" for 4, "8-Core Intel Xeon W" for 8). The SMBIOS ProcessorType must make macOS pick
# exactly that string: left at 0, OpenCore derives "Core i3" from the 2 GHz clock and the rename never applies.
PROCESSOR_TYPE = {4: 0x0605, 8: 0x0F01}   # Core i5, Xeon W
if cpu_name and cores not in PROCESSOR_TYPE:
    print(f"warning: CPU_NAME needs VM_CORES=4 or 8 (got {cores}); leaving the CPU name alone", file=sys.stderr)
    cpu_name = ""

boot_args = ["keepsyms=1",
             # NullMoth: framebuffer + accelerator, 4 heads; the AMFI args let WindowServer load the driver bundle
             "nvfb=1", "nvaccel=1", "nvfbheads=4", "-nvkmsnosmooth",
             "amfi_get_out_of_my_way=0x1", "amfi=0x80", "ipc_control_port_options=0"]
if cpu_name:
    # only the CPU-name patch; the CPU is presented as GenuineIntel, which needs revcpu=1
    boot_args += ["revpatch=cpuname", "revcpu=1"]
if variant == "nvidia":
    # -nvaccelnoheadless: in the VM the GPU takes ~100 s to light up its port. The driver's 60 s headless check
    # (meant for laptops whose panel is on the iGPU) would give up first and withhold the GPU from WindowServer,
    # which then asserts in CoreDisplay and restarts forever.
    boot_args += ["-v", "-nvaccelnoheadless"]
# Troubleshooting, e.g. EXTRA_BOOT_ARGS="debug=0x100" (a panic stays on screen instead of rebooting)
boot_args += os.environ.get("EXTRA_BOOT_ARGS", "").split()
c["NVRAM"]["Add"][NV]["boot-args"] = " ".join(boot_args)
c["NVRAM"]["Add"][NV]["csr-active-config"] = bytes.fromhex("430A0000")   # 0x0A43, the value NullMoth tests with
for key in ("boot-args", "csr-active-config"):
    if key not in c["NVRAM"]["Delete"][NV]:
        c["NVRAM"]["Delete"][NV].append(key)

if cpu_name:
    # contains spaces, so it cannot be a boot-arg
    c["NVRAM"]["Add"].setdefault(RE, {})["revcpuname"] = cpu_name
    c["NVRAM"]["Delete"].setdefault(RE, [])
    if "revcpuname" not in c["NVRAM"]["Delete"][RE]:
        c["NVRAM"]["Delete"][RE].append("revcpuname")
    c["PlatformInfo"]["Generic"]["ProcessorType"] = PROCESSOR_TYPE[cores]

c["Misc"]["Security"]["SecureBootModel"] = "Disabled"            # Apple Secure Boot refuses unsigned kexts
c["PlatformInfo"]["Generic"]["SystemProductName"] = "iMacPro1,1"  # the model NullMoth is tested with

kexts = c["Kernel"]["Add"]
for k in kexts:
    # no Intel/AMD GPU in the VM; with WhateverGreen gone the driver's gfxrst=4 requirement goes too
    if k["BundlePath"] == "WhateverGreen.kext":
        k["Enabled"] = False
    # OSX-KVM's config names it AppleMCEReporterDisabler.kext but ships MCEReporterDisabler.kext, so it never loads.
    # iMac19,1 doesn't need it; with iMacPro1,1 AppleIntelMCEReporter panics (NULL dereference) in a VM.
    if k["BundlePath"] == "AppleMCEReporterDisabler.kext":
        k["BundlePath"] = "MCEReporterDisabler.kext"
lilu = next(i for i, k in enumerate(kexts) if k["BundlePath"] == "Lilu.kext")
for name, comment in (("RestrictEvents", "CPU name in About This Mac"), ("AMFIPass", "required by the NullMoth driver")):
    kexts.insert(lilu + 1, {
        "Arch": "x86_64", "BundlePath": f"{name}.kext", "Comment": comment, "Enabled": True,
        "ExecutablePath": f"Contents/MacOS/{name}", "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist",
    })

if variant == "nvidia":
    # Passthrough boots have no usable pointer before macOS (Deskflow starts after login), and the picker defaults to
    # OpenCore's own disk ("EFI"). Scan only APFS on SATA and skip the picker: boot straight into macOS.
    # FILE_SYSTEM_LOCK | DEVICE_LOCK | ALLOW_FS_APFS | ALLOW_DEVICE_SATA. Use the imacpro image for recovery.
    c["Misc"]["Security"]["ScanPolicy"] = 0x1 | 0x2 | 0x100 | 0x10000
    c["Misc"]["Boot"]["ShowPicker"] = False
    # Ignore keys during OpenCore: with the evdev fallback the user's keyboard belongs to the VM from power-on, and
    # anything typed at that moment (e.g. the Shift+Shift toggle) brought the picker up and left the boot waiting.
    c["Misc"]["Boot"]["PollAppleHotKeys"] = False
    # NullMoth README: otherwise the firmware framebuffer takes display index 0 from NVRMFB
    c["Kernel"]["Block"].append({
        "Arch": "Any", "Comment": "NullMoth: keep display index 0 for NVRMFB", "Enabled": True,
        "Identifier": "com.apple.iokit.IONDRVSupport", "MaxKernel": "", "MinKernel": "", "Strategy": "Exclude",
    })

plistlib.dump(c, open(dst, "wb"))
