#!/usr/bin/env bash
# Every host change the GPU-passthrough VM needs, behind one entry point. Run with sudo from your own account:
#
#   sudo scripts/host.sh status     list each change and its current state (read-only)
#   sudo scripts/host.sh prepare    apply the permanent configuration (3, 4, 7, 8) and keep the GPU on the host
#   sudo scripts/host.sh on         prepare + hand the GPU to vfio-pci + raise memlock for this terminal
#   sudo scripts/host.sh off        give the GPU back to the host driver (after the VM is shut down); the host desktop
#                                   gets the dGPU's ports (HDMI) back at the next login
#   sudo scripts/host.sh rollback   undo everything below
#
# Changes (rollback undoes all of them; backups and markers live in state/host-backup/):
#   1  ~/.config/environment.d/90-macos-vm-kwin.conf      KWIN_DRM_DEVICES=<iGPU>: KWin drives only the iGPU, so it
#                                                          does not keep the dGPU open (KDE Plasma Wayland).
#                                                          Written by `on`, removed by `off` (see kwin_igpu_only)
#   1b /etc/udev/rules.d/90-macos-vm-host-igpu.rules      only if KWIN_DRM_DEVICE does not exist: a colon-free symlink
#                                                          to the iGPU card node (KWIN_DRM_DEVICES is ':'-separated)
#   2  ~/.config/systemd/user/plasma-kwin_wayland.service.d/90-macos-vm-egl-mesa.conf
#                                                          KWin loads only Mesa's EGL; glvnd would otherwise load
#                                                          NVIDIA's EGL first and KWin keeps a context on the dGPU.
#                                                          Written by `on`, removed by `off`
#   3  /etc/systemd/system/user@.service.d/90-vfio-memlock.conf       LimitMEMLOCK=infinity: VFIO pins all guest RAM.
#                                                          Desktop sessions are started by the systemd user manager,
#                                                          so /etc/security/limits.d has no effect on them
#   4  /etc/modprobe.d/kvm.conf                            options kvm ignore_msrs=1 (macOS reads MSRs KVM doesn't
#                                                          emulate); only created/removed if absent before
#   5  runtime: GPU + audio bound to vfio-pci, nvidia modules unloaded, nvidia-powerd stopped
#   6  runtime: GPU BAR1 resized to BAR1_VM_LOG2_MB (Resizable BAR); off/rollback/reboot restore the original
#   7  Deskflow installed with pacman (only removed by rollback if this script installed it)
#   8  ~/.config/Deskflow/Deskflow.conf from deskflow/linux-Deskflow.conf.in (server on 127.0.0.1 only)
# 1/2/8 take effect at the next login, 3/4 at the next boot. `on` also raises memlock for the terminal that ran
# sudo (and any running `claude` agent), so QEMU started from there works without rebooting.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ $(id -u) == 0 && -n ${SUDO_USER:-} ]] || die "usage: sudo $0 status|prepare|on|off|rollback (run with sudo from your own account)"
U=$SUDO_USER; UID_=$(id -u "$U"); UH=$(getent passwd "$U" | cut -d: -f6)
as_user() { runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus "$@"; }
[[ -n $GPU_GROUP ]] || die "$GPU_PCI has no IOMMU group: is the IOMMU enabled (amd_iommu/intel_iommu)?"

BK=$STATE/host-backup
NV_MODS=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
KWIN_ENV=$UH/.config/environment.d/90-macos-vm-kwin.conf
IGPU_RULE=/etc/udev/rules.d/90-macos-vm-host-igpu.rules
EGL_DROPIN=$UH/.config/systemd/user/plasma-kwin_wayland.service.d/90-macos-vm-egl-mesa.conf
MEMLOCK=/etc/systemd/system/user@.service.d/90-vfio-memlock.conf
KVM=/etc/modprobe.d/kvm.conf
DF_CONF=$UH/.config/Deskflow/Deskflow.conf
DF_LINE="externalConfigFile=$ROOT/deskflow/server.conf"

drv() { if [[ -e /sys/bus/pci/devices/$1/driver ]]; then basename "$(readlink -f "/sys/bus/pci/devices/$1/driver")"; else echo none; fi; }
have() { [[ -e $1 ]] && echo "set" || echo "not set"; }
memlock_of() { awk '/Max locked memory/{print $4}' "/proc/$1/limits" 2>/dev/null; }
bar1_bytes() { awk 'NR==2{print strtonum($2)-strtonum($1)+1}' "/sys/bus/pci/devices/$GPU_PCI/resource"; }
bar1_log2mb() { local mb=$(( $(bar1_bytes) >> 20 )) n=0; while (( mb > 1 )); do mb=$(( mb >> 1 )); n=$(( n + 1 )); done; echo $n; }
# The BAR can only be resized while no driver is bound
set_bar1() {
  [[ -e /sys/bus/pci/devices/$GPU_PCI/resource1_resize && -n $1 ]] || return 0
  [[ $(drv "$GPU_PCI") == none ]] || echo "$GPU_PCI" > "/sys/bus/pci/devices/$GPU_PCI/driver/unbind"
  echo "$1" > "/sys/bus/pci/devices/$GPU_PCI/resource1_resize"
}
kwin_live() {
  local p; p=$(pgrep -u "$U" -x kwin_wayland | head -1) || { echo "KWin not running"; return; }
  tr '\0' '\n' < "/proc/$p/environ" | grep -qx "KWIN_DRM_DEVICES=$KWIN_DRM_DEVICE" && echo "active in this session" || echo "not active yet: log out and back in"
}

status() {
  echo "1  KWin iGPU only            $(have "$KWIN_ENV") ($(kwin_live))"
  echo "1b iGPU udev symlink         $(have "$IGPU_RULE") ($KWIN_DRM_DEVICE $([[ -e $KWIN_DRM_DEVICE ]] && echo exists || echo missing))"
  echo "2  KWin Mesa-only EGL        $(have "$EGL_DROPIN")"
  echo "3  user manager memlock      $(have "$MEMLOCK") (user manager now: $(memlock_of "$(pgrep -u "$U" -x systemd | head -1)"))"
  echo "4  kvm ignore_msrs           $(have "$KVM")$([[ -e $BK/kvm.conf.created ]] && echo ", created by host.sh") (now: $(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null))"
  echo "5  GPU driver                $GPU_PCI $(drv "$GPU_PCI") / $GPU_AUDIO_PCI $(drv "$GPU_AUDIO_PCI") (IOMMU group $GPU_GROUP)"
  echo "6  GPU BAR1                  $(( $(bar1_bytes) >> 20 ))M$([[ -e $BK/bar1-host-log2mb ]] && echo " (host original: $(( 1 << $(cat "$BK/bar1-host-log2mb") ))M)")"
  echo "7  deskflow                  $(pacman -Q deskflow 2>/dev/null || command -v deskflow || echo "not installed")$([[ -e $BK/deskflow.installed ]] && echo ", installed by host.sh")"
  echo "8  Deskflow server settings  $(grep -qx "$DF_LINE" "$DF_CONF" 2>/dev/null && echo set || echo "not set")"
  echo "   memlock of the shell that ran sudo: $(memlock_of "$(ps -o ppid= -p $PPID | tr -d ' ')")"
}

apply_config() {
  mkdir -p "$BK"; chown "$U:" "$BK"
  # 1b
  if [[ ! -e $KWIN_DRM_DEVICE && ! -e $IGPU_RULE ]]; then
    printf '# written by %s\nKERNEL=="card*", KERNELS=="%s", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", SYMLINK+="%s"\n' \
      "$0" "$HOST_IGPU_PCI" "${KWIN_DRM_DEVICE#/dev/}" > "$IGPU_RULE"
    udevadm control --reload && udevadm trigger --subsystem-match=drm
  fi
  # 3 + 4
  mkdir -p "$(dirname "$MEMLOCK")"
  printf '# written by %s: VFIO passthrough pins all guest RAM\n[Service]\nLimitMEMLOCK=infinity\n' "$0" > "$MEMLOCK"
  systemctl daemon-reload
  if [[ ! -e $KVM ]]; then echo 'options kvm ignore_msrs=1 report_ignored_msrs=0' > "$KVM"; touch "$BK/kvm.conf.created"; fi
  echo 1 > /sys/module/kvm/parameters/ignore_msrs
  # Earlier versions asked for a limits.d entry, which desktop sessions never apply; drop it if it is exactly ours
  local old=/etc/security/limits.d/99-vfio-memlock.conf
  if [[ -e $old && $(cat "$old") == "$U - memlock unlimited" ]]; then rm -f "$old"; rmdir /etc/security/limits.d 2>/dev/null || true; fi
  # 7
  if ! command -v deskflow >/dev/null; then
    if command -v pacman >/dev/null; then pacman -S --needed --noconfirm deskflow && touch "$BK/deskflow.installed"
    else echo "install Deskflow with your package manager (https://github.com/deskflow/deskflow)"; fi
  fi
  # 8 (Deskflow adds its own keys to this file, so only check our line; back up a pre-existing file once)
  if ! grep -qx "$DF_LINE" "$DF_CONF" 2>/dev/null; then
    [[ ! -e $DF_CONF || -e $BK/Deskflow.conf.orig ]] || cp -p "$DF_CONF" "$BK/Deskflow.conf.orig"
    as_user mkdir -p "$(dirname "$DF_CONF")"
    sed "s|@ROOT@|$ROOT|g; s|@PORT@|$DESKFLOW_PORT|g" "$ROOT/deskflow/linux-Deskflow.conf.in" | as_user tee "$DF_CONF" >/dev/null
  fi
}

# 1 + 2 only while the VM is in use: KWin reads them at login. `on` writes them (one log out/in before the first
# handover); `off` removes them, so at the next login the host desktop uses the dGPU's ports (e.g. HDMI) again.
kwin_igpu_only() {
  as_user mkdir -p "$(dirname "$KWIN_ENV")" "$(dirname "$EGL_DROPIN")"
  printf '# written by %s: KWin uses only the iGPU so the dGPU can be passed to the macOS VM\nKWIN_DRM_DEVICES=%s\n' \
    "$0" "$KWIN_DRM_DEVICE" | as_user tee "$KWIN_ENV" >/dev/null
  printf '# written by %s: no NVIDIA EGL in KWin, so the dGPU can be passed to the macOS VM\n[Service]\nEnvironment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json\n' \
    "$0" | as_user tee "$EGL_DROPIN" >/dev/null
  as_user systemctl --user daemon-reload || true
}
kwin_all_gpus() {
  rm -f "$KWIN_ENV" "$EGL_DROPIN"; rmdir "$(dirname "$EGL_DROPIN")" 2>/dev/null || true
  as_user systemctl --user daemon-reload || true
}

bind_gpu() {
  if [[ $(drv "$GPU_PCI") == vfio-pci && $(drv "$GPU_AUDIO_PCI") == vfio-pci ]]; then
    if [[ -n $BAR1_VM_LOG2_MB && $(bar1_log2mb) != "$BAR1_VM_LOG2_MB" ]]; then
      fuser "/dev/vfio/$GPU_GROUP" >/dev/null 2>&1 && die "BAR1 is still $(( $(bar1_bytes) >> 20 ))M but the VM is running: shut it down first"
      set_bar1 "$BAR1_VM_LOG2_MB"; echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    fi
    chown "$U" "/dev/vfio/$GPU_GROUP"; return
  fi
  local holders
  holders=$(fuser /dev/nvidia* "/dev/dri/by-path/pci-$GPU_PCI-card" "/dev/dri/by-path/pci-$GPU_PCI-render" 2>/dev/null | tr -s ' ' || true)
  holders=$(for p in $holders; do [[ $(cat "/proc/$p/comm" 2>/dev/null) == nvidia-powerd ]] || echo "$p"; done | sort -u)
  if [[ -n $holders ]]; then
    echo "These processes still use the GPU; it was not handed over:"
    for p in $holders; do echo "  $p $(tr '\0' ' ' < "/proc/$p/cmdline" | cut -c1-100)"; done
    echo "If it is KWin/Xwayland: KWin is now set to use only the iGPU from the next login."
    echo "Log out and back in once, then run sudo $0 on again."
    exit 1
  fi
  systemctl stop nvidia-powerd.service 2>/dev/null || true
  if ! modprobe -r "${NV_MODS[@]}"; then
    lsmod | grep -E '^nvidia' || true
    systemctl start nvidia-powerd.service 2>/dev/null || true
    die "could not unload the nvidia modules"
  fi
  modprobe vfio-pci
  for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    [[ $(drv "$dev") == none ]] || echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"
    echo vfio-pci > "/sys/bus/pci/devices/$dev/driver_override"
  done
  # Remember the host's BAR1 size once, before the first resize
  [[ -e $BK/bar1-host-log2mb ]] || bar1_log2mb > "$BK/bar1-host-log2mb"
  set_bar1 "$BAR1_VM_LOG2_MB"
  for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do echo "$dev" > /sys/bus/pci/drivers_probe; done
  chown "$U" "/dev/vfio/$GPU_GROUP"
}

unbind_gpu() {
  [[ $(drv "$GPU_PCI") == vfio-pci || $(drv "$GPU_AUDIO_PCI") == vfio-pci ]] || return 0
  fuser "/dev/vfio/$GPU_GROUP" >/dev/null 2>&1 && die "/dev/vfio/$GPU_GROUP is still in use: shut the VM down first"
  for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    [[ $(drv "$dev") == none ]] || echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"
    echo > "/sys/bus/pci/devices/$dev/driver_override"
  done
  [[ ! -e $BK/bar1-host-log2mb ]] || set_bar1 "$(cat "$BK/bar1-host-log2mb")"
  modprobe nvidia_drm; modprobe nvidia_uvm
  for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do echo "$dev" > /sys/bus/pci/drivers_probe; done
  systemctl start nvidia-powerd.service 2>/dev/null || true
}

case "${1:-}" in
status) status ;;
prepare) apply_config; status ;;
on)
  apply_config
  kwin_igpu_only
  bind_gpu
  # 3 needs a reboot for running sessions: raise memlock for the shell that ran sudo (QEMU started there inherits it)
  # and for running Claude Code agents, which start QEMU from their own shells.
  shell=$(ps -o ppid= -p $PPID | tr -d ' ')
  for p in $shell $(pgrep -u "$U" -x claude || true); do prlimit --pid "$p" --memlock=unlimited:unlimited; done
  status
  ;;
off)
  unbind_gpu
  kwin_all_gpus
  status
  echo "The GPU is back on the host driver. The host desktop uses its ports (e.g. HDMI) again from the next login."
  ;;
rollback)
  unbind_gpu
  rm -f "$BK/bar1-host-log2mb"
  kwin_all_gpus
  if [[ -e $IGPU_RULE ]]; then rm -f "$IGPU_RULE"; udevadm control --reload; fi
  rm -f "$MEMLOCK"; rmdir "$(dirname "$MEMLOCK")" 2>/dev/null || true
  systemctl daemon-reload
  if [[ -e $BK/kvm.conf.created ]]; then rm -f "$KVM" "$BK/kvm.conf.created"; fi
  if [[ -e $BK/Deskflow.conf.orig ]]; then cp -p "$BK/Deskflow.conf.orig" "$DF_CONF" && rm -f "$BK/Deskflow.conf.orig"; else rm -f "$DF_CONF"; fi
  if [[ -e $BK/deskflow.installed ]]; then pacman -Rns --noconfirm deskflow && rm -f "$BK/deskflow.installed"; fi
  status
  echo "Everything is undone. KWin settings revert at the next login, memlock/ignore_msrs at the next boot."
  ;;
*) die "usage: sudo $0 status|prepare|on|off|rollback" ;;
esac
