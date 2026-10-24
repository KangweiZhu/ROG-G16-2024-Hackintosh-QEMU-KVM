#!/usr/bin/env bash
# Start the macOS VM (derived from OSX-KVM's OpenCore-Boot.sh).
#
#   scripts/boot-macos.sh                 install / maintenance: emulated display in a QEMU window
#   PASSTHROUGH=1 scripts/boot-macos.sh   pass the NVIDIA GPU through; the picture comes out of the GPU's own port
#
# Environment:
#   PASSTHROUGH=1   needs `sudo scripts/host.sh on` first
#   EVDEV=0         passthrough without the evdev keyboard/mouse fallback (default on)
#   OPENCORE_IMG=   override the OpenCore disk (default: state/opencore/OpenCore-{nvidia,imacpro}.qcow2,
#                   state/OSX-KVM/OpenCore/OpenCore.qcow2 is OSX-KVM's stock image)
#
# Differences from OSX-KVM's script:
#   - no sound card: hda-duplex keeps the host microphone open (Bluetooth headsets drop to HFP)
#   - QMP socket at state/qmp.sock for scripts/qmp.py
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$STATE"

CPU_OPTS="+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"
if [[ "${PASSTHROUGH:-0}" == 1 ]]; then
  OPENCORE_IMG="${OPENCORE_IMG:-$STATE/opencore/OpenCore-nvidia.qcow2}"
else
  OPENCORE_IMG="${OPENCORE_IMG:-$STATE/opencore/OpenCore-imacpro.qcow2}"
fi
[[ -f $OPENCORE_IMG ]] || die "$OPENCORE_IMG missing: run opencore/build.sh"

args=(
  -name macos-sequoia
  -enable-kvm -m "$VM_RAM_MIB"
  # Do NOT add model-id=<your CPU>: changing the CPUID brand string stops the boot ("not supported").
  # The name in "About This Mac" comes from RestrictEvents instead (CPU_NAME in config.env).
  # -pcid/-rdseed: AMD hosts lack PCID and KVM doesn't expose RDSEED.
  -cpu "Skylake-Client,-hle,-rtm,-pcid,-rdseed,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,$CPU_OPTS"
  -machine q35
  -smp "$((VM_CORES * VM_THREADS))",cores="$VM_CORES",threads="$VM_THREADS",sockets=1
  -device qemu-xhci,id=xhci
  -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0
  -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  -drive if=pflash,format=raw,readonly=on,file=OSX-KVM/OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file=OVMF_VARS.fd
  -smbios type=2
  -device ich9-ahci,id=sata
  -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$OPENCORE_IMG"
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot
  -drive id=Recovery,if=none,snapshot=on,format=raw,file=recovery.img
  -device ide-hd,bus=sata.3,drive=Recovery
  # discard=unmap: blocks macOS frees (TRIM) are released from mac.qcow2, so the file shrinks again.
  # rotation_rate=1 reports an SSD: macOS then shows "TRIM Support: Yes" and trims (no trimforce needed).
  -drive id=MacHDD,if=none,format=qcow2,file=mac.qcow2,discard=unmap,detect-zeroes=unmap
  -device ide-hd,bus=sata.4,drive=MacHDD,rotation_rate=1
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$VNC_PORT-:5900"
  -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
  -qmp "unix:$QMP_SOCK,server=on,wait=off"
  -monitor none
)

if [[ "${PASSTHROUGH:-0}" == 1 ]]; then
  # VFIO pins all guest RAM; the default memlock limit is 8 MiB.
  lim=$(ulimit -l)
  if [[ $lim != unlimited ]] && (( lim < (VM_RAM_MIB + 1024) * 1024 )); then
    die "memlock limit ${lim}K is too small for ${VM_RAM_MIB}M of guest RAM: run sudo scripts/host.sh on"
  fi
  [[ -n $GPU_GROUP && -w /dev/vfio/$GPU_GROUP ]] || die "/dev/vfio/$GPU_GROUP missing or not writable: run sudo scripts/host.sh on"
  args+=(
    # Room for large 64-bit BARs. Without it OVMF leaves the GPU's BARs unassigned and macOS never sees the card.
    -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536
    # On the root bus, as in OSX-KVM's passthrough notes. Behind a pcie-root-port macOS reads the slot as
    # empty (no presence detect, no DLLLA) and never scans it, even with hotplug=off.
    -device vfio-pci,host="$GPU_PCI",bus=pcie.0,addr=0x10.0,multifunction=on
    -device vfio-pci,host="$GPU_AUDIO_PCI",bus=pcie.0,addr=0x10.1
    # Relative-pointer device for the evdev mouse (usb-tablet is absolute only). It must exist from power-on:
    # hot-plugged later, the firmware and OpenCore picker never see it.
    -device usb-mouse,bus=xhci.0,id=evmouse
    # No emulated display. With vmware-svga as the boot display macOS gets both a firmware framebuffer
    # (IONDRVSupport, display 0) and NVRMFB, and WindowServer asserts in CoreDisplay and restarts forever.
    # OpenCore's Kernel->Block cannot exclude IONDRVSupport (it lives in the System KC).
    # The GPU's own GOP shows the firmware/OpenCore screens on its port instead.
    -vga none -display none
  )
else
  args+=(-device vmware-svga -display gtk,zoom-to-fit=on)
fi

if [[ "${PASSTHROUGH:-0}" == 1 && "${EVDEV:-1}" == 1 ]]; then
  # Fallback input: hand the keyboards/mouse in EVDEV_DEVICES to the VM as soon as QEMU is up
  # (works in firmware, the OpenCore picker and the login window). Both Shift keys toggle host/VM.
  # Once macOS is logged in, Deskflow is the everyday path.
  # With the picker-less nvidia disk, wait until OpenCore is past: keys typed while the keyboard suddenly belongs
  # to the VM must not reach OpenCore. With other disks (picker wanted) attach at once.
  delay=0; [[ $OPENCORE_IMG == *OpenCore-nvidia.qcow2 ]] && delay=20
  ( sleep "$delay"; for _ in $(seq 20); do sleep 1; [[ -S $QMP_SOCK ]] && python3 "$ROOT/scripts/qmp.py" input-attach >/dev/null 2>&1 && break; done ) &
fi
exec qemu-system-x86_64 "${args[@]}"
