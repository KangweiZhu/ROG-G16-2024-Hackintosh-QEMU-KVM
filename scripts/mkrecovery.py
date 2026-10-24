"""Make a FAT32 raw disk image holding com.apple.recovery.boot/ so OpenCore can boot recovery from the dmg directly.

  mkrecovery.py <dir with BaseSystem.dmg + BaseSystem.chunklist> <out.img>

No dmg2img/LZFSE needed: OpenCore reads the dmg itself. Run with:
  uv run --with pyfatfs --with 'setuptools<81' python mkrecovery.py ...
"""
import os, shutil, sys
from pyfatfs.PyFat import PyFat
from pyfatfs.PyFatFS import PyFatFS

src, img = sys.argv[1], sys.argv[2]
size = sum(os.path.getsize(os.path.join(src, n)) for n in os.listdir(src)) + (300 << 20)
with open(img, "wb") as f:
    f.truncate(size)
pf = PyFat()
pf.mkfs(img, fat_type=PyFat.FAT_TYPE_FAT32, label="RECOVERY")
pf.close()
with PyFatFS(img) as v:
    v.makedir("/com.apple.recovery.boot")
    for name in sorted(os.listdir(src)):
        with open(os.path.join(src, name), "rb") as i, v.openbin(f"/com.apple.recovery.boot/{name}", "w") as o:
            shutil.copyfileobj(i, o, 8 << 20)
    for n in v.listdir("/com.apple.recovery.boot"):
        print(n, v.getsize(f"/com.apple.recovery.boot/{n}"))
