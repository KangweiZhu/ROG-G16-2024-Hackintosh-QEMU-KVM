#!/usr/bin/env bash
# Download and prepare everything under state/ (idempotent: finished steps are skipped).
#   1. OSX-KVM at a pinned commit (OVMF firmware, OpenCore.qcow2, fetch-macOS-v2.py)
#   2. pinned releases, each checked against its SHA-256: AMFIPass, Lilu, RestrictEvents, the NullMoth driver, Deskflow for macOS
#   3. kexts unpacked into state/kexts/{release,debug}
#   4. macOS Sequoia recovery from Apple, packed into state/recovery.img
#   5. an empty 160 GB system disk and a fresh UEFI variable store
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
mkdir -p "$STATE/downloads"
cd "$STATE"

OSX_KVM_COMMIT=4c378a4b5e0b219783683012bec680325eb40719
OCLP_COMMIT=76516394fddb7ce4526ccbcc5b806795c30e9a89

# name|url|sha256
DOWNLOADS=(
  "AMFIPass-v1.4.1-RELEASE.zip|https://github.com/dortania/OpenCore-Legacy-Patcher/raw/$OCLP_COMMIT/payloads/Kexts/Acidanthera/AMFIPass-v1.4.1-RELEASE.zip|07b266145906db41f4b13a7938fbb173ea28888cc1fa65f84417f8820adc961e"
  "Lilu-1.7.2-RELEASE.zip|https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip|53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8"
  "Lilu-1.7.2-DEBUG.zip|https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-DEBUG.zip|e95df95d82e8b151047abf359ecd9c853755c59293e19dfcc3907da8fbd8cf89"
  "RestrictEvents-1.1.6-RELEASE.zip|https://github.com/acidanthera/RestrictEvents/releases/download/1.1.6/RestrictEvents-1.1.6-RELEASE.zip|98170dfae195ddd28b5d95e3f040125a13ca783bcb9bd1e5b8c588e217b14ee6"
  "RestrictEvents-1.1.6-DEBUG.zip|https://github.com/acidanthera/RestrictEvents/releases/download/1.1.6/RestrictEvents-1.1.6-DEBUG.zip|6ff7b0a28dbee66429fb50c588f50e43f0c231245182a4f7a7542e934956ec86"
  "nullmoth-nvidia-2.5.3.tar.gz|https://github.com/nullmoth/nvidia-macos-driver/releases/download/v2.5.3/nullmoth-nvidia-2.5.3.tar.gz|6ec9d23f8d7e0ab340b9e0a9753f7c48722b9930118fff648d545e0b95016884"
  "deskflow-1.27.0-macos-x86_64.dmg|https://github.com/deskflow/deskflow/releases/download/v1.27.0/deskflow-1.27.0-macos-x86_64.dmg|8aca3c77a1b16b9a3d6b8a380e5e38a0e6abf6d241bb32dcf3cf8b67abbff5d8"
)

step() { echo; echo "== $*"; }

step "OSX-KVM @ ${OSX_KVM_COMMIT:0:12}"
if [[ ! -d OSX-KVM/.git ]]; then git clone https://github.com/kholia/OSX-KVM.git OSX-KVM; fi
if [[ $(git -C OSX-KVM rev-parse HEAD) != "$OSX_KVM_COMMIT" ]]; then
  git -C OSX-KVM fetch origin && git -C OSX-KVM checkout -q "$OSX_KVM_COMMIT"
fi

step "downloads"
for d in "${DOWNLOADS[@]}"; do
  IFS='|' read -r name url sha <<< "$d"
  f=downloads/$name
  if [[ ! -f $f ]] || ! echo "$sha  $f" | sha256sum -c --quiet 2>/dev/null; then
    curl -fL --retry 3 -o "$f.part" "$url"
    echo "$sha  $f.part" | sha256sum -c --quiet || die "checksum mismatch: $name"
    mv "$f.part" "$f"
  fi
  echo "ok  $name"
done

step "kexts"
for flavor in release debug; do
  mkdir -p "kexts/$flavor"
  FLAVOR=${flavor^^}
  for z in "Lilu-1.7.2-$FLAVOR.zip" "RestrictEvents-1.1.6-$FLAVOR.zip" AMFIPass-v1.4.1-RELEASE.zip; do
    tmp=$(mktemp -d); bsdtar -xf "downloads/$z" -C "$tmp"
    for k in "$tmp"/*.kext; do rm -rf "kexts/$flavor/$(basename "$k")"; mv "$k" "kexts/$flavor/"; done
    rm -rf "$tmp"
  done
  ls "kexts/$flavor"
done

step "recovery (macOS Sequoia, from Apple)"
if [[ ! -f recovery.img ]]; then
  if [[ ! -f recovery/com.apple.recovery.boot/BaseSystem.dmg ]]; then
    mkdir -p recovery/com.apple.recovery.boot
    python3 OSX-KVM/fetch-macOS-v2.py -s sequoia -o recovery/com.apple.recovery.boot
  fi
  uv run -q --with pyfatfs --with 'setuptools<81' python "$ROOT/scripts/mkrecovery.py" recovery/com.apple.recovery.boot recovery.img
fi
echo "ok  recovery.img"

step "system disk and UEFI variables"
[[ -f mac.qcow2 ]] || qemu-img create -f qcow2 mac.qcow2 160G
[[ -f OVMF_VARS.fd ]] || cp OSX-KVM/OVMF_VARS.fd OVMF_VARS.fd
echo "ok  mac.qcow2, OVMF_VARS.fd"

echo; echo "Next: opencore/build.sh"
