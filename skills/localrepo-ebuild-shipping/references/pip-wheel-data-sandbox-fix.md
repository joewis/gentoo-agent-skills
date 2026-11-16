# pip-wheel `.data/data` sandbox violation — manual-unzip fix

## Symptom

A pip-installed wheel fails in the `install` phase with a sandbox access
violation on a path at the **real prefix root**, e.g.:

```
ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied: '/usr/COPYING'
F: rename / unlink
S: deny
P: /usr/COPYING
C: ... pip install --no-build-isolation --no-deps --no-index --progress-bar off --root=<image> --prefix=/usr <wheel>
```

The image dir ends up empty (pip died before writing anything), so the smoke
test finds no binary.

## Root cause

The wheel ships a `.data/data/<file>` entry (e.g. `piper_tts-1.8.0.data/data/COPYING`).
pip installs `.data/data/*` to the **real** prefix root (`/usr/COPYING`),
**ignoring `--root`**. The sandbox denies the write to the live filesystem.

## Fixes that DON'T work

1. `addpredict /usr/COPYING` in `src_install()` — pip still resolves to the
   real path and fails with the same OSError.
2. Stripping the file from the wheel in `src_unpack()` — pip reads the wheel's
   `RECORD` and still attempts the install, failing again.

## Working fix: unzip the wheel manually into the image dir

Skip pip entirely. The wheel is a self-contained manylinux abi3 wheel, so a
manual unzip into `${D}` is equivalent. Map `.data/data/*` to `${D}/usr/`,
skip the offending file, preserve modes from `external_attr`.

```bash
src_install() {
	local whl="${S}/piper_tts-${PV}-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.manylinux_2_28_x86_64.whl"
	python3 - "${whl}" "${D}" <<'EOF'
import sys, zipfile, os, shutil
whl, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(whl) as z:
    for item in z.infolist():
        name = item.filename
        # Skip the .data/data/COPYING that would land at the prefix root.
        if name == "piper_tts-1.8.0.data/data/COPYING":
            continue
        # Map .data/data/* to the prefix root (usr/), everything else as-is.
        if name.startswith("piper_tts-1.8.0.data/data/"):
            rel = name[len("piper_tts-1.8.0.data/data/"):]
            target = os.path.join(dest, "usr", rel)
        elif name.startswith("piper_tts-1.8.0.data/"):
            continue  # scripts/headers dirs not needed for this wheel
        else:
            target = os.path.join(dest, name)
        if item.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(item) as src, open(target, "wb") as out:
            shutil.copyfileobj(src, out)
        os.chmod(target, item.external_attr >> 16 & 0o777 or 0o644)
EOF
}
```

## Detection

Before writing a pip-wheel ebuild, inspect the wheel's top-level entries:
```bash
python3 -c "import zipfile; z=zipfile.ZipFile('<whl>'); [print(n) for n in z.namelist() if '.data/' in n]"
```
If any `.data/data/` file exists, use the manual-unzip pattern from the start.
The trap appears on a **version bump** — an older wheel (e.g. piper-tts 1.4.2)
may lack the `.data/data` file while the newer one (1.8.0) adds it.
