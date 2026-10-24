#!/usr/bin/env bash
# Build the two OpenCore disks from OSX-KVM's OpenCore.qcow2 (left untouched as a fallback):
#   state/opencore/OpenCore-imacpro.qcow2  emulated display: boot picker, NullMoth boot-args/csr, AMFIPass, RestrictEvents
#   state/opencore/OpenCore-nvidia.qcow2   passthrough: same + verbose boot, no picker, IONDRVSupport excluded
#
# Needs scripts/fetch.sh to have run (OSX-KVM checkout and kexts in state/).
# Troubleshooting: DEBUG_KEXTS=1 EXTRA_BOOT_ARGS="-liludbgall -revdbg liludump=120" opencore/build.sh
#   uses the DEBUG Lilu/RestrictEvents; the log ends up in the guest's /var/log/Lilu_*.txt.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
source "$HERE/../scripts/lib.sh"
export CPU_NAME VM_CORES
UVPY=(uv run -q --with pyfatfs --with 'setuptools<81' python)
KEXTS=$STATE/kexts/$([[ "${DEBUG_KEXTS:-0}" == 1 ]] && echo debug || echo release)
for k in AMFIPass Lilu RestrictEvents; do [[ -d $KEXTS/$k.kext ]] || die "$KEXTS/$k.kext missing: run scripts/fetch.sh"; done

OUT=$STATE/opencore; mkdir -p "$OUT"; cd "$OUT"
qemu-img convert -O raw "$STATE/OSX-KVM/OpenCore/OpenCore.qcow2" orig.raw
"${UVPY[@]}" "$HERE/esp.py" orig.raw get /EFI/OC/config.plist orig-config.plist 2>/dev/null

for variant in imacpro nvidia; do
  python3 "$HERE/patch-config.py" orig-config.plist "config-$variant.plist" "$variant"
  cp --sparse=always orig.raw "$variant.raw"
  "${UVPY[@]}" "$HERE/esp.py" "$variant.raw" put "config-$variant.plist" /EFI/OC/config.plist 2>/dev/null
  # OSX-KVM ships Lilu 1.6.8; replace it with the current release along with the added kexts
  for k in AMFIPass Lilu RestrictEvents; do
    "${UVPY[@]}" "$HERE/esp.py" "$variant.raw" putdir "$KEXTS/$k.kext" "/EFI/OC/Kexts/$k.kext" 2>/dev/null
  done
  # Write a new file and rename it: a running QEMU keeps the old one open and picks up the new one next boot
  qemu-img convert -O qcow2 "$variant.raw" "OpenCore-$variant.new.qcow2"
  mv -f "OpenCore-$variant.new.qcow2" "OpenCore-$variant.qcow2"
  rm "$variant.raw"
  echo "$OUT/OpenCore-$variant.qcow2"
done
rm orig.raw
