# Live Binary Wheel Ebuilds Deployed in localrepo

## sci-libs/onnxruntime 1.27.0

**Ebuild:** `/var/db/repos/localrepo/sci-libs/onnxruntime/`
**Wheel:** `cp314-cp314` (Python 3.14 specific — NOT ABI3!)
**Runs on:** EliteDesk, Gentoo with PYTHON_TARGETS="python3_14"
**RDEPEND:** dev-python/numpy (build from source via Gentoo)

**Key points:**
- onnxruntime does NOT ship an ABI3 wheel — each Python version gets its own wheel
- The `cp314-cp314` wheel means it ONLY works with CPython 3.14
- If the system upgrades Python, the wheel filename changes (e.g. `cp315-cp315`)
- Free-threaded variant (`cp314-cp314t`) also exists — don't use it unless needed

**SRC_URI extraction pattern:**
```bash
curl -sL "https://pypi.org/pypi/onnxruntime/1.27.0/json" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for url_info in d['urls']:
    f = url_info['filename']
    if 'manylinux' in f and 'x86_64' in f and 'cp314-cp314' in f and 't' not in f.split('-')[2]:
        print(url_info['url'])
"
```

## app-text/piper-tts 1.4.2

**Ebuild:** `/var/db/repos/localrepo/app-text/piper-tts/`
**Wheel:** `cp39-abi3` (stable ABI, works with Python ≥3.9)
**RDEPEND:** dev-python/pathvalidate, sci-libs/onnxruntime

**Key points:**
- Uses ABI3 stable ABI — same wheel works across all Python 3.x versions
- Bundles espeak-ng data (~5400 files) + C extension (`espeakbridge.so`)
- onnxruntime is listed as a pip requirement but installed via Gentoo RDEPEND

## Version bumps

To bump either:
1. Get the new wheel URL from PyPI JSON API
2. Update SRC_URI in the ebuild
3. `sudo pkgdev manifest` (fetches new file, updates checksums)
4. `sudo emerge -v =cat/pkg-version`
