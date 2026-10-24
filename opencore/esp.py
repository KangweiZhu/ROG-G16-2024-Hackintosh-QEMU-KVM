"""Read/write the ESP inside a raw OpenCore disk image (GPT partition 1, starting at sector 2048).

  esp.py IMG ls              list every file
  esp.py IMG get SRC DST     copy a file out
  esp.py IMG put SRC DST     copy a file in (replacing it)
  esp.py IMG putdir SRC DST  copy a directory in (e.g. a kext), replacing it

Run with: uv run --with pyfatfs --with 'setuptools<81' python esp.py ...
"""
import os, shutil, sys, warnings
warnings.filterwarnings("ignore")
from pyfatfs.PyFatFS import PyFatFS

img, op, *a = sys.argv[1:]
with PyFatFS(img, offset=2048 * 512) as v:
    if op == "ls":
        for p in sorted(v.walk.files("/")): print(v.getsize(p), p)
    elif op == "get":
        with v.openbin(a[0]) as i, open(a[1], "wb") as o: shutil.copyfileobj(i, o)
    elif op == "put":
        # pyfatfs corrupts the cluster chain when overwriting in place: delete first
        if v.exists(a[1]): v.remove(a[1])
        with open(a[0], "rb") as i, v.openbin(a[1], "w") as o: shutil.copyfileobj(i, o)
    elif op == "putdir":
        if v.exists(a[1]): v.removetree(a[1])
        for root, dirs, files in os.walk(a[0]):
            d = a[1] + root[len(a[0]):]
            v.makedirs(d, recreate=True)
            for n in files:
                with open(os.path.join(root, n), "rb") as i, v.openbin(f"{d}/{n}", "w") as o: shutil.copyfileobj(i, o)
