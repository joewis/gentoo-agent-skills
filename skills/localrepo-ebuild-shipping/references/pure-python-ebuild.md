# Pure-Python Ebuild Pattern

For packages that are pure Python (no C extensions, no build system) and whose runtime deps (torch, numpy, etc.) are installed via pip or are already on the system.

## When to use this pattern

- The package is a pure-Python module (`.py` files only, no `.so`, no `setup.py` build step)
- The package's runtime dependencies are heavy C++ packages (like pytorch) that are impractical to build via Portage
- The user already has those deps installed via pip in a venv or system-wide

## The ebuild

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{12,13,14} )
inherit python-single-r1

DESCRIPTION="One-line description"
HOMEPAGE="https://github.com/owner/repo"
SRC_URI="https://github.com/owner/repo/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz"

S="${WORKDIR}/RepoName-${PV}"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"

# No Portage-level deps — torch/torchaudio are runtime deps
# installed separately via pip or the system's pytorch.
RDEPEND="
	${PYTHON_DEPS}
"
BDEPEND="
	${PYTHON_DEPS}
"

# Pure Python, no compilation
src_compile() {
	:
}

src_install() {
	python_domodule <module_dir>
	dodoc README.md
}

pkg_postinst() {
	elog "${PN} ${PV} installed."
	elog ""
	elog "Runtime requirements (install separately):"
	elog "  torch (>=2.0) — pip install torch"
	elog "  torchaudio    — pip install torchaudio"
	elog ""
	elog "Usage:"
	elog "  from <module> import <class>"
}
```

## Key decisions

| Decision | Why |
|---|---|
| **No `DEPEND`** | The package has no C extensions to compile. Pure Python. |
| **No `RDEPEND` on pytorch** | Portage's pytorch pulls in caffe2 + a full C++ build chain. The user already has torch via pip. |
| **`pkg_postinst` with hints** | Tells the user what runtime deps are needed and how to install them. |
| **`python-single-r1`** | Single-impl Python (not multi-impl) — the package is a tool, not a library. |
| **`python_domodule`** | Installs the module dir to the correct site-packages path for the active Python impl. |

## Pitfalls

- **`python_domodule` is from `python-utils-r1`** (inherited by `python-single-r1`). It installs a directory to `site-packages/`. Don't use `doins -r` — that puts files in the wrong place.
- **`src_compile() { : }`** is required — without it, Portage tries to run `default` which may fail if there's no Makefile.
- **The `S` variable** must match the extracted tarball directory name. GitHub archives use `RepoName-PV` format. Check with `tar tf` if unsure.
- **`pkgcheck` will warn about `PythonCompatUpdate`** (e.g., `python3_15` available) — this is cosmetic for localrepo ebuilds.
- **`pkgcheck` will warn about `UnknownUseFlags`** if you define `IUSE` flags not in the global `use.desc` — harmless for localrepo.
