#!/usr/bin/env bash
# Configure the macOS guest over SSH (run on the host while the VM is up).
#
#   scripts/guest.sh ssh            create state/ssh/ (key + config) and install the key in the guest (asks the password once)
#   scripts/guest.sh prefs          no automatic macOS updates (a newer macOS can break the driver), no sleep
#   scripts/guest.sh autologin      log in automatically at boot (passthrough boots have no input before login)
#   scripts/guest.sh screensharing  start Screen Sharing; then toggle it off/on once in System Settings (see README)
#   scripts/guest.sh driver         install the NullMoth driver (the GPU must be passed through: PASSTHROUGH=1)
#   scripts/guest.sh deskflow       install Deskflow, point it at the host, start it at login
#   scripts/guest.sh shell          open an SSH shell in the guest
#
# Prerequisite: Remote Login enabled in the guest (System Settings > General > Sharing > Remote Login).
# The guest password is read from the terminal when sudo needs it and is never written to disk.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
SSH=(ssh -F "$SSH_CONFIG" macvm)
SCP=(scp -F "$SSH_CONFIG" -q)

ask_password() { [[ -n ${GUEST_PW:-} ]] || { read -rsp "macOS password for $MAC_USER: " GUEST_PW; echo; }; }
# run a command in the guest as root; the password goes to sudo on stdin
gsudo() { ask_password; printf '%s\n' "$GUEST_PW" | "${SSH[@]}" "sudo -S -p '' sh -c $(printf '%q' "$1")"; }

case "${1:-}" in
ssh)
  [[ -n ${MAC_USER:-} ]] || die "set MAC_USER in config.env"
  mkdir -p "$STATE/ssh"; chmod 700 "$STATE/ssh"
  [[ -f $STATE/ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -C macos-vm -f "$STATE/ssh/id_ed25519"
  cat > "$SSH_CONFIG" <<EOF
Host macvm
  HostName 127.0.0.1
  Port $SSH_PORT
  User $MAC_USER
  IdentityFile $STATE/ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $STATE/ssh/known_hosts
EOF
  ssh-copy-id -F "$SSH_CONFIG" -i "$STATE/ssh/id_ed25519.pub" macvm
  "${SSH[@]}" 'sw_vers'
  ;;
prefs)
  gsudo '
    for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do
      defaults write /Library/Preferences/com.apple.SoftwareUpdate $k -bool false
    done
    defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
    pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0
    bless --mount / --setBoot'
  echo "automatic updates off, sleep off"
  ;;
autologin)
  ask_password
  # /etc/kcpassword: the password XOR-ed with Apple's fixed key, padded to a multiple of 12 bytes
  kc=$(printf '%s' "$GUEST_PW" | python3 -c '
import sys
key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
pw = sys.stdin.buffer.read()
pw += b"\0" * (12 - len(pw) % 12)
print(bytes(b ^ key[i % len(key)] for i, b in enumerate(pw)).hex())' | tr -d '\n')
  gsudo "echo $kc | xxd -r -p > /etc/kcpassword && chmod 600 /etc/kcpassword && chown root:wheel /etc/kcpassword
         defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser '$MAC_USER'
         fdesetup status"
  ;;
screensharing)
  gsudo 'launchctl enable system/com.apple.screensharing; launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true'
  echo "Screen Sharing listens on 127.0.0.1:$VNC_PORT. Before the first connection, open System Settings > General > Sharing"
  echo "in the guest and switch Screen Sharing off and on once, or the picture stays black (TCC screen-capture permission)."
  echo "Connect with: vncviewer 127.0.0.1::$VNC_PORT  (macOS user name + password)"
  ;;
driver)
  pkg=$STATE/downloads/nullmoth-nvidia-2.5.3.tar.gz
  [[ -f $pkg ]] || die "$pkg missing: run scripts/fetch.sh"
  "${SSH[@]}" 'ioreg -r -c IOPCIDevice -d 1 | grep -q "\"vendor-id\" = <de100000>"' \
    || die "no NVIDIA GPU visible in the guest: boot with PASSTHROUGH=1 first"
  "${SSH[@]}" 'mkdir -p ~/nullmoth'
  "${SCP[@]}" "$pkg" macvm:nullmoth/
  "${SSH[@]}" 'cd ~/nullmoth && rm -rf pkgroot && tar -xzf nullmoth-nvidia-*.tar.gz && cd pkgroot && shasum -a 256 -c SHA256SUMS | grep -v ": OK$" || true'
  gsudo 'cd ~'"$MAC_USER"'/nullmoth/pkgroot && CHECK=1 ./install.sh | grep -v "^CHECK runtime" && ./install.sh | grep -v "^CHECK runtime"'
  echo "Installed. Reboot the guest; the first start pauses up to ~2 minutes while the GPU comes up."
  ;;
deskflow)
  dmg=$STATE/downloads/deskflow-1.27.0-macos-x86_64.dmg
  [[ -f $dmg ]] || die "$dmg missing: run scripts/fetch.sh"
  "${SSH[@]}" 'mkdir -p ~/nullmoth ~/Library/Deskflow ~/Library/LaunchAgents'
  "${SCP[@]}" "$dmg" macvm:nullmoth/
  # the dmg has a licence agreement: `yes` accepts it
  gsudo 'm=$(yes | hdiutil attach -nobrowse -readonly ~'"$MAC_USER"'/nullmoth/deskflow-*.dmg | grep -o "/Volumes/.*" | tail -1)
         rm -rf /Applications/Deskflow.app && ditto "$m/Deskflow.app" /Applications/Deskflow.app; hdiutil detach "$m" >/dev/null'
  "${SSH[@]}" 'cat > ~/Library/Deskflow/Deskflow.conf' < <(sed "s|@PORT@|$DESKFLOW_PORT|g" "$ROOT/deskflow/mac-Deskflow.conf.in")
  # Start at login and act as a watchdog: the Deskflow window does not restart its client process when it dies
  # (seen once, ~10 s after login: "uncaught exception ... event queue"), so every 30 s restart the app if no
  # client is running.
  "${SSH[@]}" 'launchctl unload ~/Library/LaunchAgents/local.deskflow.autostart.plist 2>/dev/null; cat > ~/Library/LaunchAgents/local.deskflow.autostart.plist && launchctl load ~/Library/LaunchAgents/local.deskflow.autostart.plist' <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.deskflow.autostart</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
<string>pgrep -qf "deskflow-core client" || { pkill -x Deskflow; sleep 1; open -g -a /Applications/Deskflow.app; }</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>30</integer>
</dict></plist>
EOF
  echo "Deskflow installed; starts at login and is restarted if its client dies. Allow it in System Settings > Privacy & Security > Accessibility."
  ;;
shell) exec "${SSH[@]}" ;;
*) sed -n '2,13p' "$0"; exit 1 ;;
esac
