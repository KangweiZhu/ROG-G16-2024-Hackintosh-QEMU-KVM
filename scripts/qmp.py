#!/usr/bin/env python3
"""Control the running VM over QMP (state/qmp.sock).

  qmp.py shot out.png       screenshot (only with the emulated display, not in passthrough mode)
  qmp.py key ret right ...  press keys (QEMU qcode names; "ctrl+ret" for chords), one after another
  qmp.py type text          type lowercase letters, digits and spaces
  qmp.py click X Y [W H]    left click at screenshot pixel X,Y (default screen 1280x800)
  qmp.py powerdown          ACPI power button
  qmp.py quit               kill QEMU immediately (only when the guest is hung or still at the boot picker)
  qmp.py input-attach       give the EVDEV_DEVICES from config.env to the VM (both Shift keys toggle host/VM)
  qmp.py input-detach       give them back to the host
"""
import json, os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
cfg = dict(line.split("=", 1) for line in subprocess.run(
    ["bash", "-c", f'source "{HERE}/lib.sh" && printf "%s\\n" "QMP_SOCK=$QMP_SOCK" "EVDEV_DEVICES=$EVDEV_DEVICES" "EVDEV_TOGGLE=$EVDEV_TOGGLE"'],
    check=True, capture_output=True, text=True).stdout.splitlines())

s = socket.socket(socket.AF_UNIX); s.connect(cfg["QMP_SOCK"]); f = s.makefile("rw")
def cmd(c, **a):
    f.write(json.dumps({"execute": c, "arguments": a} if a else {"execute": c}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
json.loads(f.readline()); cmd("qmp_capabilities")

op = sys.argv[1] if len(sys.argv) > 1 else "-h"
if op == "shot":
    print(cmd("screendump", filename=os.path.abspath(sys.argv[2]), format="png"))
elif op == "key":
    for k in sys.argv[2:]:
        print(k, cmd("send-key", keys=[{"type": "qcode", "data": x} for x in k.split("+")])); time.sleep(0.3)
elif op == "type":
    for ch in sys.argv[2]:
        cmd("send-key", keys=[{"type": "qcode", "data": "spc" if ch == " " else ch}]); time.sleep(0.05)
elif op == "click":
    x, y = int(sys.argv[2]), int(sys.argv[3])
    w, h = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else (1280, 800)
    move = [{"type": "abs", "data": {"axis": "x", "value": x * 32767 // (w - 1)}},
            {"type": "abs", "data": {"axis": "y", "value": y * 32767 // (h - 1)}}]
    print(cmd("input-send-event", events=move)); time.sleep(0.2)
    for down in (True, False):
        cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}]); time.sleep(0.1)
elif op == "powerdown":
    print(cmd("system_powerdown"))
elif op == "quit":
    print(cmd("quit"))
elif op in ("input-attach", "input-detach"):
    names = [n for n in cfg["EVDEV_DEVICES"].split("|") if n]
    existing = {o["name"] for o in cmd("qom-list", path="/objects")["return"]}
    if op == "input-detach":
        for i in range(len(names)):
            if f"evdev{i}" in existing: print(names[i], cmd("object-del", id=f"evdev{i}"))
        sys.exit(0)
    # Event node numbers change between boots: look the devices up by name.
    devs = {}
    for blk in open("/proc/bus/input/devices").read().split("\n\n"):
        name = next((l.split('"')[1] for l in blk.splitlines() if l.startswith("N: Name=")), None)
        ev = next((h for l in blk.splitlines() if l.startswith("H: Handlers=") for h in l.split("=")[1].split() if h.startswith("event")), None)
        if name in names and ev: devs[name] = "/dev/input/" + ev
    # The mouse is relative and usb-tablet takes absolute events only. boot-macos.sh adds usb-mouse at power-on.
    if not any(o["name"] == "evmouse" for o in cmd("qom-list", path="/machine/peripheral")["return"]):
        print(cmd("device_add", driver="usb-mouse", bus="xhci.0", id="evmouse"))
    for i, n in enumerate(names):
        if n not in devs: print("not found:", n); continue
        if f"evdev{i}" in existing: continue
        # The toggle is detected per device, so every keyboard needs grab_all + the toggle keys.
        print(n, devs[n], cmd("object-add", **{"qom-type": "input-linux", "id": f"evdev{i}", "evdev": devs[n],
              "repeat": True, "grab_all": True, "grab-toggle": cfg["EVDEV_TOGGLE"]}))
else:
    print(__doc__)
