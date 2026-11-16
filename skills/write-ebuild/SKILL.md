---
name: write-ebuild
description: "Write a Gentoo ebuild from scratch: skeleton, variables, phases, dependencies, patches, and Manifest generation using pkgdev."
---

# Write a Gentoo Ebuild

Write ebuild files (`.ebuild`) for Gentoo Portage — the bash scripts that tell the package manager how to download, configure, build, and install software.

## ⚠️ When NOT to write an ebuild

Before starting, decide whether an ebuild is the right approach. These projects are usually NOT good ebuild candidates:

**Developer tools / frameworks that document "Running Locally" with a dev command (e.g. `make dev`, `npm run dev`, `go run main.go`).**
These are designed to be cloned and run in a terminal — not installed as a system daemon. An ebuild does work, but adds complexity (Node.js + Go toolchains as build deps) for little benefit over `git clone && make dev`.

**Docker-first deployments.** If the project's primary production deployment is Docker (Dockerfile + docker-compose.yml with all env vars), an ebuild is the wrong container. Just use Docker.

**Projects with very new toolchain requirements** (e.g. `go 1.26+`, `node 26+`) not yet available in ::gentoo stable. You'll be fighting keyword masking and live ebuilds from the start.

**TL;DR:** Ebuilds are right for libraries, system tools, daemons, and CLI tools that get installed use-only on a Gentoo system. They're wrong for development frameworks, web apps meant to run under Docker, or anything whose README says "clone and run `make dev`".

If in doubt, ask the user what they actually want to do with it (run it vs install it) before writing an ebuild.

## Prerequisites

- `sys-apps/portage` (for the `ebuild` command)
- `app-portage/pkgdev` (for `pkgdev manifest`)
- `app-portage/pkgcheck` (for QA scanning)
- An ebuild repository (e.g. `/var/db/repos/localrepo/`)

## Template / Skeleton

Start from the official Gentoo skeleton:

```bash
cp /var/db/repos/gentoo/skel.ebuild /var/db/repos/localrepo/<category>/<package>/<package>-<version>.ebuild
```

Or use the minimal template with Vim (if `app-vim/gentoo-syntax` is installed):

```bash
mkdir -p /var/db/repos/localrepo/<category>/<package>
cd /var/db/repos/localrepo/<category>/<package>
vim <package>-<version>.ebuild
```

## Mandatory Variables

These must be set in every ebuild:

```bash
# Copyright header — required; update the year
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Short description of the package"
HOMEPAGE="https://example.com/"
SRC_URI="https://example.com/downloads/${P}.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~x86"
```

| Variable | Purpose | Example |
|----------|---------|---------|
| `EAPI` | Ebuild API version. Use `8` (current stable). See [EAPI docs](https://wiki.gentoo.org/wiki/EAPI). | `EAPI=8` |
| `DESCRIPTION` | One-line description of the package | `"A happy little package"` |
| `HOMEPAGE` | Project website URL(s) | `"https://example.com/"` |
| `SRC_URI` | Upstream source download URL(s) | `"https://example.com/${P}.tar.gz"` |
| `LICENSE` | License(s) of the package | `"GPL-2"` or `"Apache-2.0 BSD"` |
| `SLOT` | Slot number (usually `0` for single-instance) | `"0"` or `"7"` |
| `KEYWORDS` | Architectures this ebuild targets; `~` means testing/unstable | `"~amd64 ~x86 ~arm64"` |

## Variable Order (Critical)

pkgcheck enforces the exact skel.ebuild variable order. The expected sequence is:
```
DESCRIPTION → HOMEPAGE → SRC_URI → S → LICENSE → SLOT → KEYWORDS → IUSE → RESTRICT
```
Put `S` immediately after `SRC_URI` (before `LICENSE`) to avoid `VariableOrderWrong` warnings:
```bash
SRC_URI="..."
S="${WORKDIR}/llama.cpp-b${PV}"
LICENSE="MIT"
```

## Optional Variables

### IUSE — USE flags

```bash
IUSE="X alsa gtk qt5 +ssl minimal"
# Prefix with + to enable by default
```

### Dependency Variables

```bash
# Build-time only dependencies (tools needed to compile)
BDEPEND="
    virtual/pkgconfig
    >=dev-lang/go-1.20
"

# Build-time + run-time dependencies (libraries linked against)
DEPEND="
    >=dev-libs/openssl-1.1:=
    media-libs/libpng:0=
"

# Run-time only dependencies (shared libs, interpreters, fonts, etc.)
RDEPEND="
    ${DEPEND}
    virtual/ffmpeg
    !app-misc/other-implementation
"

# Optional test dependencies
BDEPEND+=" test? ( dev-util/cppunit )"
```

### Dependency Atom Reference

| Syntax | Meaning | Example |
|--------|---------|---------|
| `cat/pkg` | Any version | `dev-libs/openssl` |
| `cat/pkg-1.2.3` | Exact version | `app-misc/scrub-2.6.1` |
| `>=cat/pkg-1.2` | Minimum version | `>=dev-lang/python-3.10` |
| `~cat/pkg-1.2.3` | That version, any revision | `~net-libs/libnet-1.0.2a` |
| `=cat/pkg-1.2*` | Version range (1.2.x) | `=x11-libs/qt-3*` |
| `!cat/pkg` | Block (conflict) | `!app-text/dos2unix` |
| `cat/pkg:SLOT` | Specific slot | `x11-libs/qt:3` |
| `cat/pkg:SLOT/SUBSLOT` | Sub-slot | `dev-libs/glib:2/2.30` |
| `cat/pkg:SLOT=` | Sub-slot tracking | `dev-libs/glib:2=` |
| `cat/pkg[flag]` | USE-conditional | `media-video/ffmpeg[threads]` |
| `cat/pkg[-flag]` | Disabled USE flag | `media-video/ffmpeg[-x264]` |
| `usevar? ( dep )` | Conditional dep | `gtk? ( x11-libs/gtk+:3 )` |
| `|| ( dep1 dep2 )` | Any-of (pick one) | `|| ( app-games/ut app-games/ut-goty )` |

### Other Variables

```bash
# Custom source directory (if tarball extracts to a different dir name)
S="${WORKDIR}/${P}"

# Patches to apply during src_prepare
PATCHES=(
    "${FILESDIR}/${P}-fix-build.patch"
    "${FILESDIR}/${P}-add-feature.patch"
)
```

## Phase Functions

Portage calls these functions in order. You only need to override what's non-standard.

### src_unpack — Unpack the source

Override only if you have custom unpacking (e.g. VCS checkouts):

```bash
src_unpack() {
    default    # calls the default unpack
    # or custom:
    git clone https://github.com/example/repo.git "${S}"
}
```

### src_prepare — Patch and prepare source

```bash
src_prepare() {
    default    # applies PATCHES array, then runs autotools if needed
    # or custom:
    sed -i 's|/usr/local|/usr|' Makefile
}
```

### src_configure — Configure the build

```bash
src_configure() {
    default    # runs ./configure for autotools projects
    # or custom for cmake:
    cmake -B build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        $(cmake_use_find_package X11 X11) \
        $(cmake_use_find_package alsa ALSA)
}
```

Eclasses available for common build systems:
- `inherit cmake` — CMake-based projects
- `inherit meson` — Meson-based projects
- `inherit cargo` — Rust/Cargo projects
- `inherit go-module` — Go projects with modules
- `inherit autotools` — Autotools (autoreconf, etc.)
- `inherit python-any-r1` — Python-based builds
- `inherit nodejs` — Node.js/JS projects

### src_compile — Compile the source

```bash
src_compile() {
    default    # runs make for autotools
    # or custom:
    emake -C src
    # or cmake:
    cmake --build build
}
```

### src_test — Run the test suite

```bash
src_test() {
    default    # runs make test / check
    # or custom:
    emake test
}
```

### src_install — Install to ${D}

```bash
src_install() {
    default    # runs make install DESTDIR=${D}
    # or custom:
    emake DESTDIR="${D}" install
    # install docs:
    dodoc README.md CHANGELOG
    # install HTML docs:
    dohtml -r docs/
    # install config files:
    insinto /etc
    doins "${FILESDIR}/myapp.conf"
}
```

### pkg_pretend — Pre-install checks (EAPI 5+)

```bash
pkg_pretend() {
    if [[ ${MERGE_TYPE} != buildonly ]]; then
        has_version ">=sys-devel/gcc-10" || die "Need GCC >= 10"
    fi
}
```

### pkg_setup — User/group creation, environment setup

```bash
pkg_setup() {
    enewgroup myapp
    enewuser myapp -1 /bin/bash /var/lib/myapp
}
```

### pkg_preinst / pkg_postinst / pkg_prerm / pkg_postrm

```bash
pkg_postinst() {
    elog "MyApp has been installed."
    elog "See /usr/share/doc/${PF}/README.md for configuration."
}
```

## Built-in Variables (read-only, set by Portage)

| Variable | Meaning | Example |
|----------|---------|---------|
| `P` | PN-PV (name-version) | `scrub-2.6.1` |
| `PN` | Package name | `scrub` |
| `PV` | Version (no revision) | `2.6.1` |
| `PR` | Revision | `r0` or `r1` |
| `PVR` | Version with revision | `2.6.1-r1` |
| `PF` | Full package name | `scrub-2.6.1-r1` |
| `CATEGORY` | Category | `app-misc` |
| `A` | All source files (from SRC_URI) | `scrub-2.6.1.tar.gz` |
| `WORKDIR` | Build root | `/var/tmp/portage/app-misc/scrub-2.6.1/work` |
| `S` | Source directory (default: `${WORKDIR}/${P}`) | |
| `D` | Install image directory | `/var/tmp/portage/app-misc/scrub-2.6.1/image/` |
| `ED` | Install image with offset prefix | `${D%/}${EPREFIX}/` |
| `T` | Temp directory (logs, etc.) | `/var/tmp/portage/app-misc/scrub-2.6.1/temp` |
| `FILESDIR` | Files directory in the repo | `.../files` |
| `ROOT` | Live filesystem root | `"/"` or (EAPI 7+) `""` |
| `EPREFIX` | Offset prefix (for prefix installs) | |
| `BROOT` | Build-dependency root (EAPI 7+) | `${EPREFIX}` |

## Helper Functions (From Portage)

| Function | Purpose |
|----------|---------|
| `default` | Run the default phase implementation |
| `econf` | Run `./configure` with standard Gentoo flags |
| `emake` | Run `make` with `MAKEOPTS` and parallel jobs |
| `dobin <files>` | Install binaries to `/usr/bin` |
| `dolib <files>` | Install libraries |
| `dolib.a <files>` | Install static libraries |
| `dolib.so <files>` | Install shared libraries |
| `doman <files>` | Install man pages |
| `doinfo <files>` | Install info pages |
| `dodoc <files>` | Install documentation |
| `dohtml <dir>` | Install HTML docs |
| `dosed <expr>` | Run sed on already-installed files |
| `newbin <file> <newname>` | Install bin with a different name |
| `insinto <dir>` | Set destination for `doins` |
| `doins <files>` | Install arbitrary files |
| `doexe <files>` | Install executable files |
| `newins <file> <newname>` | Install file with different name |
| `exeinto <dir>` | Set destination for `doexe` |
| `dosbin <files>` | Install system binaries |
| `fowners <user:group> <paths>` | Set file owners (in image) |
| `fperms <mode> <paths>` | Set file permissions (in image) |
| `into <dir>` | Set base install prefix |
| `keepdir <dirs>` | Create and preserve empty directories |
| `dosym <target> <link>` | Create a symbolic link |
| `doenvd <files>` | Install env.d files |
| `einstall` | Run `make install` (deprecated; use `emake DESTDIR="${D}" install`) |
| `enewgroup <group> [gid]` | Create group during `pkg_setup` |
| `enewuser <user> [uid] [shell] [homedir] [groups]` | Create user during `pkg_setup` |
| `elog <msg>` | Log message during install |
| `ewarn <msg>` | Log warning |
| `einfo <msg>` | Log info |
| `die <msg>` | Abort with error message |

## Common Eclass Reference

Include with `inherit <eclass>` at the top (after EAPI, before variables):

| Eclass | For |
|--------|-----|
| `autotools` | Packages needing `autoreconf`, `eautoreconf`, `eaclocal` |
| `bash-completion-r1` | Bash completion files |
| `cargo` | Rust/Cargo packages |
| `cmake` | CMake-based packages (provides `cmake_src_configure` default) |
| `desktop` | Desktop file utilities (`make_desktop_entry`) |
| `flag-o-matic` | Compiler flag manipulation |
| `gobject-introspection` | GObject introspection |
| `go-module` | Go packages with modules |
| `gnome2` | GNOME packages (common gnome2 defaults) |
| `java-pkg-2` | Java packages |
| `kde-frameworks` | KDE Frameworks 5/6 |
| `linux-info` | Linux kernel version/feature checks |
| `meson` | Meson build system |
| `multilib` | Multiarch/multilib support |
| `nodejs` | Node.js/JavaScript packages |
| `perl-module` | Perl module packages |
| `python-any-r1` | Python-based build tools (not installed) |
| `python-single-r1` | Single-impl Python packages |
| `python-r1` | Multi-impl Python packages |
| `qt6-build` | Qt 6 packages |
| `scons-utils` | SCons build system |
| `systemd` | Systemd unit file utilities |
| `tmpfiles` | Systemd tmpfiles.d utilities |
| `toolchain-funcs` | Toolchain queries (`tc-getCC`, etc.) |
| `user-info` | User/group checks during build |
| `vcs-snapshot` | Snapshot tarballs from VCS tags |
| `xdg` | XDG desktop integration |
| `xorg-3` | X.Org packages |

## Example Ebuilds

### Minimal autotools package

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Simple command-line file scrubber"
HOMEPAGE="https://github.com/chaos/scrub"
SRC_URI="https://github.com/chaos/scrub/archive/refs/tags/${PV}.tar.gz -> ${P}.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~x86"

src_prepare() {
    default
    # Fix install path in Makefile
    sed -i 's|/usr/local|/usr|' Makefile.in || die
}
```

### CMake package with USE flags

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit cmake

DESCRIPTION="Modern C++ utility library"
HOMEPAGE="https://github.com/example/fmtlib"
SRC_URI="https://github.com/example/fmtlib/archive/${PV}.tar.gz -> ${P}.tar.gz"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm64"
IUSE="doc test"

RDEPEND=""
DEPEND="${RDEPEND}"
BDEPEND="test? ( dev-cpp/gtest )"

src_configure() {
    local mycmakeargs=(
        -DFMT_DOC=NO
        -DFMT_TEST=$(usex test)
    )
    cmake_src_configure
}
```

### Go module package

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit go-module

DESCRIPTION="Fast web link checker"
HOMEPAGE="https://github.com/example/linkcheck"
SRC_URI="https://github.com/example/linkcheck/archive/v${PV}.tar.gz -> ${P}.tar.gz"

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="~amd64"

src_compile() {
    ego build -o linkcheck .
}

src_install() {
    dobin linkcheck
    dodoc README.md
}
```

**`EGO_SUM` is deprecated — pkgcheck warns on it.** For a `go-module` ebuild, the
modern way to vendor dependencies is `go-module_live_vendor`, called from `src_unpack`
after the source is fetched. It vendors the module tree at build time, so no deps
tarball or `EGO_SUM` is needed at all:

```bash
src_unpack() {
    default
    go-module_live_vendor
}
```

That said, `EGO_SUM` still works and is what most versioned ::gentoo ebuilds use —
the warning is a deprecation notice, not a build failure. The real tradeoff is
reproducibility: `EGO_SUM` pins the exact `go.sum` contents, while `go-module_live_vendor`
re-resolves against the module proxy at build time. For a versioned release ebuild
where the `go.sum` is part of the published tarball, `EGO_SUM` is the honest pin;
for a live ebuild, `go-module_live_vendor` is the only option that makes sense.

**Do not vendor deps into `files/`.** A vendored tarball placed in `files/` trips
pkgcheck's `SizeViolation` and `MissingUri` (files are relative paths with no fetch
URL). Vendor deps belong in a distfile mirror (`/var/cache/distfiles/` or a `file://`
mirror), or better, not at all — use `go-module_live_vendor` and let the build
resolve them.

## Adding an Ebuild to localrepo

### Step-by-step deployment

After writing the ebuild, add it to the localrepo:

1. Create directories: `sudo mkdir -p /var/db/repos/localrepo/<category>/<package>`
2. Place the ebuild file:
   - **New ebuild you wrote:** `sudo cp <package>-<version>.ebuild /var/db/repos/localrepo/<category>/<package>/`
   - **Existing ebuild from ::gentoo** (includes patches, files, etc.): `sudo cp -rv /var/db/repos/gentoo/<category>/<package>/* /var/db/repos/localrepo/<category>/<package>/`
3. Fix permissions: `sudo chown -R portage:portage /var/db/repos/localrepo`
4. Generate Manifest: `cd /var/db/repos/localrepo/<category>/<package>/ && sudo pkgdev manifest`
5. Run QA checks: `cd /var/db/repos/localrepo/<category>/<package>/ && pkgcheck scan`
6. Quick test: `GENTOO_MIRRORS="" sudo ebuild ./<package>-<version>.ebuild clean unpack`
7. Full test: `sudo ebuild ./<package>-<version>.ebuild clean test install`
8. Install: `sudo emerge --ask --verbose <category>/<package>`

**Quick reference table:**

| Action | Command |
|--------|---------|
| Create directories | `sudo mkdir -p /var/db/repos/localrepo/<cat>/<pkg>` |
| Copy new ebuild | `sudo cp <file> /var/db/repos/localrepo/<cat>/<pkg>/` |
| Copy from ::gentoo | `sudo cp -rv /var/db/repos/gentoo/<cat>/<pkg>/* /var/db/repos/localrepo/<cat>/<pkg>/` |
| Fix permissions | `sudo chown -R portage:portage /var/db/repos/localrepo` |
| Generate Manifest | `cd /var/db/repos/localrepo/<cat>/<pkg>/ && sudo pkgdev manifest` |
| QA check | `cd /var/db/repos/localrepo/<cat>/<pkg>/ && pkgcheck scan` |
| Quick test | `GENTOO_MIRRORS="" sudo ebuild <path>/<pkg>-<ver>.ebuild clean unpack` |
| Install | `sudo emerge --ask --verbose <cat>/<pkg>` |

### Version bump

```bash
cd /var/db/repos/localrepo/<category>/<package>/
sudo cp <package>-<old>.ebuild <package>-<new>.ebuild
# Edit the new ebuild, then re-run Manifest + tests
```

### Setting up a localrepo from scratch

Ensure the repository is registered in `/etc/portage/repos.conf/localrepo.conf`:
```ini
[localrepo]
location = /var/db/repos/localrepo
masters = gentoo
auto-sync = no
```

**IMPORTANT:** Missing `masters = gentoo` is a common oversight — the localrepo section often exists but lacks it, causing cross-repo dependency resolution to fail silently (or with confusing "dependency unavailable" errors). Always check for this.

## Testing

Quick test cycle:

```bash
# 1. Generate Manifest
cd /var/db/repos/localrepo/<category>/<package>
sudo pkgdev manifest

# 2. QA scan
pkgcheck scan

# 3. Test fetch + unpack
GENTOO_MIRRORS="" sudo ebuild ./<package>-<version>.ebuild manifest clean unpack

# 4. Full build + test + install to image
sudo ebuild ./<package>-<version>.ebuild clean test install

# 5. Merge into live system (once ready)
sudo emerge -v =<category>/<package>-<version>
```

**Note:** Do NOT use `--ask`/`-a` in non-interactive contexts (cron, scripts, agent terminal). `--ask` exits immediately with `"\"--ask\" should only be used in a terminal"` when stdin isn't a TTY. Use `-v` (verbose) instead. Set USE flags via `/etc/portage/package.use/` before emerging.

## pkgcheck Deep Reference

Run `pkgcheck scan` after every manifest generation. Common warnings and how to fix them:

### UnknownUseFlags
`version 9784: unknown USE flags: 'foo', 'bar'` — the USE flag names you defined aren't in the global `use.desc`. For overlay/localrepo ebuilds this is **normal and harmless**. Only fix if submitting to the main gentoo repo (where flags need global registration).

### MissingRemoteId

`missing <remote-id type="github">org/repo</remote-id> (inferred from URI 'https://github.com/org/repo')` — pkgcheck detected a GitHub URL in `HOMEPAGE` or `SRC_URI` but no matching `<remote-id>` in `metadata.xml`. Fix: create `metadata.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE pkgmetadata SYSTEM "https://www.gentoo.org/dtd/metadata.dtd">
<pkgmetadata>
	<upstream>
		<remote-id type="github">org/repo</remote-id>
	</upstream>
	<maintainer type="person">
		<email>you@localhost</email>
		<name>Your Name</name>
	</maintainer>
</pkgmetadata>
```

Types: `github`, `gitlab`, `bitbucket`, `sourceforge`, `pypi`, `cpan`, `rubygems`, `cran`.
`variable S should occur before KEYWORDS` — pkgcheck enforces the exact skel.ebuild variable ordering:
```
DESCRIPTION → HOMEPAGE → SRC_URI → S → LICENSE → SLOT → KEYWORDS → IUSE → RESTRICT
```
Fix: move the offending variable to its correct position relative to others.

### DependencyMoved
`dependency moved, update 'sys-devel/clang:*' to 'llvm-core/clang:*'` — the package name changed in the Gentoo tree. Use the new name.

### NonexistentBlocker
`nonexistent blocker RDEPEND="!app-misc/other-pkg": no matches in repo history` — your `!cat/pkg` blocker references a package that never existed. Remove the blocker line.

### InvalidDepend / InvalidRdepend
`failed parsing DEPEND: ... flagged token: invalid package atom` — syntax error in a dependency string. Common causes:
- Wrong bracket syntax: `dev-libs/openssl:= [!static-libs]` is wrong. Use `openssl? ( dev-libs/openssl:=[static-libs?] )` or omit the bracket expression.
- Double colons or stray characters in dep strings.

### OldPackageNameDep
`depend: 'sys-devel/clang:*' uses old package name` — same as DependencyMoved. Use the new package name.

## Common Patterns

### Patch the source via PATCHES array

Place patch files in the `files/` directory next to the ebuild:

```bash
PATCHES=(
    "${FILESDIR}/${P}-fix-cross-compile.patch"
    "${FILESDIR}/${P}-add-s390x-support.patch"
)
```

### Python script tool (no build system)

For tools that are just a Python script + some data files (no setup.py, no pyproject.toml):

```bash
# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="LaTeX to DOCX conversion via pandoc"
HOMEPAGE="https://github.com/example/tex2docx"
SRC_URI="https://github.com/example/tex2docx/archive/refs/heads/main.tar.gz -> ${P}.tar.gz"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"

RDEPEND="
	app-text/pandoc-bin[pandoc-symlink]
"

S="${WORKDIR}/tex2docx-main"

src_install() {
	dobin tex2docx.py

	# support files (CSLs, examples, bibs)
	insinto /usr/share/${PN}/pandoc
	doins pandoc/*.csl

	insinto /usr/share/${PN}
	doins pandoc/pandoc_command.txt
	doins Example.tex refs.bib
}

pkg_postinst() {
	einfo ""
	einfo "Also requires the pandoc-xnos filter:"
	einfo "  pip install pandoc-xnos"
	einfo ""
}
```

**Key patterns:**
- `dobin <script.py>` — installs the script to `/usr/bin/` as-is (the `.py` stays in the name; rename with `newbin` if needed)
- `insinto <dir>` / `doins <files>` — for any data files the script references at runtime
- `pkg_postinst()` with `einfo` — for pip dependencies not in the Gentoo tree. Use `pkg_postinst` not `elog` so it shows on every install/upgrade.
- **No shebang needed** — `dobin` adds one if missing (though it's cleaner to have one)
- **No BDEPEND** — these scripts typically have no build step
- **Live (9999) ebuilds** — if there are no releases/tags, use version `9999` and `SRC_URI` pointing to the main branch archive. Accept keyword with `echo "=cat/pkg-9999 ~amd64" | sudo tee -a /etc/portage/package.accept_keywords/pkg`

### Precompiled binary package (no source compile)

For proprietary/closed-source packages that ship precompiled binaries (AppImage, tarball of binary + .so files):

```bash
# Copyright 2026-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="MyApp — proprietary application gateway"
HOMEPAGE="https://example.com/download"
SRC_URI="https://downloads.example.com/myapp_${PV}_linux.tar.gz"

LICENSE="all-rights-reserved"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="bindist mirror strip"

RDEPEND="
	sys-fs/fuse
	sys-libs/glibc
	sys-libs/zlib
"

S="${WORKDIR}/myapp_${PV}_linux"

src_compile() {
	# precompiled binary; nothing to compile
	:
}

src_install() {
	# Install the binary + bundled libs to /opt/<appname>
	insinto /opt/myapp
	doins -r "${S}"/*
	# Mark executables
	fperms 0755 /opt/myapp/myapp-binary

	# Docs
	dodoc "${S}/README.txt"

	# Wrapper script with XDG config/state directory setup
	cat > "${T}/myapp" <<-EOF
	#!/usr/bin/env bash
	set -euo pipefail

	installdir="/opt/myapp"
	config_dir="\${XDG_CONFIG_HOME:-\${HOME}/.config}/myapp"
	state_dir="\${XDG_STATE_HOME:-\${HOME}/.local/state}/myapp"
	config_file="\${config_dir}/config.xml"

	mkdir -p "\${config_dir}" "\${state_dir}"
	if [[ ! -f "\${config_file}" ]]; then
		cp "\${installdir}/config.xml.example" "\${config_file}"
		chmod 600 "\${config_file}"
	fi

	cd "\${installdir}"
	exec ./myapp-binary -cfg="\${config_file}" -log="\${state_dir}/logs" "\${@}"
	EOF
	dobin "${T}/myapp"
}

pkg_postinst() {
	elog "${PN} ${PV} installed."
	elog ""
	elog "Usage:"
	elog "  1. Edit ~/.config/myapp/config.xml with your credentials"
	elog "  2. Run: myapp"
	elog ""
	elog "See /usr/share/doc/${PF}/README.txt for more information."
}
```

**Key patterns for binary ebuilds:**
- `RESTRICT="bindist mirror strip"` — Don't create binary packages, don't mirror source, don't strip debug symbols from proprietary binaries
- `LICENSE="all-rights-reserved"` — Standard for proprietary software
- `src_compile() { : }` — No-op compile phase
- Install to `/opt/` with `insinto /opt/<appname>` — Standard FHS for third-party bundled applications
- `fperms` to mark bundled binaries as executable
- If your package has extra files (systemd units, config templates, patches), put them in `files/` next to the `.ebuild` and reference them via `${FILESDIR}/filename`
- Wrapper scripts in `/usr/bin/` that set up XDG config/state dirs and delegate to the `/opt/` binary
- `RDEPEND` lists only the **system** shared libraries the binary links against (glibc, zlib, etc.) — not the bundled ones
- After `doins -r`, use `fperms` on every binary/script inside `/opt/` that needs `+x`
- The `scanelf: Security problem NULL DT_RUNPATH` warning from precompiled binaries is harmless — it's the vendor's build, not packaging
- When the category is new (not in `/etc/portage/categories`), add it with `echo "<category>" | sudo tee -a /etc/portage/categories` before emerging
- Testing: run `GENTOO_MIRRORS="" sudo ebuild ... clean unpack` for a quick fetch+unpack test, then `sudo ebuild ... clean test install` for the full dry-run

Check bundled `ldd` linkage by extracting the tarball and running `file` and `ldd` on the main binary first to determine actual system runtime deps.

### Bare-ELF precompiled binary (no tarball, no wrapper)

Some upstreams ship a single self-contained ELF binary as a raw release asset — no tarball, no wrapper script, nothing to extract. agent-browser (Vercel Labs) is the worked example: an 18.6 MB Rust binary that links only against glibc.

```bash
# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Browser automation CLI for AI agents"
HOMEPAGE="https://github.com/vercel-labs/agent-browser"
SRC_URI="https://github.com/vercel-labs/agent-browser/releases/download/v${PV}/agent-browser-linux-x64 -> ${P}-linux-x64"

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="mirror strip"
QA_PREBUILT="*"

src_unpack() {
    mkdir -p "${S}" || die
    cp "${DISTDIR}/${A}" "${S}/${PN}" || die
    chmod 0755 "${S}/${PN}" || die
}

src_compile() {
    : # prebuilt binary, nothing to compile
}

src_install() {
    dobin "${S}/${PN}"
}

pkg_postinst() {
    elog "${PN} ${PV} installed."
    elog ""
    elog "A Chrome or Chromium browser is required at runtime. The CLI detects"
    elog "existing installations; if none is found, fetch Google's Chrome for"
    elog "Testing build (this is a runtime download, not package-managed):"
    elog "    agent-browser install"
    elog ""
    elog "That downloads into \${HOME}/.agent-browser and is roughly 390 MB."
    elog ""
    elog "Sessions and browser state also live under \${HOME}/.agent-browser."
}
```

**Pitfalls specific to this shape:**

- **`SRC_URI` basename MUST be version-stamped.** `agent-browser-linux-x64` (no `${PV}`) keeps hashing the same cached bytes across versions — the new ebuild "builds" but installs the old binary. Use `${P}-linux-x64` or `agent-browser-${PV}-linux-x64`. This is the same stale-distfile trap as the tarball case, but worse here because there is no extraction directory to catch a mismatch.
- **`src_unpack` copies, it does not `default`.** The bare ELF has no tarball, so `default` (which expects `A` to be an archive) fails. `mkdir -p "${S}"` + `cp` + `chmod` is the pattern. `S` defaults to `${WORKDIR}/${P}`, which is fine here — there is no upstream extraction dir to mismatch.
- **`RESTRICT="mirror strip"` + `QA_PREBUILT="*"`** — vendor-built binary, not ours to strip or mirror. `QA_PREBUILT` is the honest description; it does **not** silence scanelf's `Security problem NULL DT_RUNPATH` notice for vendored `.so` files (dlopen'd by path, so they carry no RUNPATH by design). Expected, exit 0 — do not chase it.
- **Runtime deps are documented, not declared.** If the binary links only glibc (`ldd` shows libm/libc/libpthread/libdl and nothing else), there is no `RDEPEND` beyond `@system`. A runtime requirement that is NOT a shared library (Chrome, in agent-browser's case) belongs in `pkg_postinst`, not in `RDEPEND` — it cannot be a hard dep because the CLI either reuses an installed browser or fetches one on demand.
- **No npm.** The npm package is a wrapper around this same ELF, and `::gentoo` has no npm eclass. Point `SRC_URI` at the release asset, not the npm tarball.

> **From .deb / .rpm sources?** See `references/deb-extraction-binary-ebuild.md` — covers SRC_URI pointing at the .deb directly, variable directory structures, and wrapper script patterns for Debian-originated binaries.

### Live (9999) ebuilds

Live ebuilds always re-emerge and fetch the latest source at install time. Two patterns exist:

#### (a) Binary-download runner ebuild (Ollama pattern)

For precompiled binaries installed via a runner script: tiny ebuild, all work done in `pkg_postinst()`.

Key patterns:
- `src_unpack() { mkdir -p "${S}"; }` — no tarball to unpack
- `src_compile() { :; }` — nothing to compile (install script does the work)
- `pkg_postinst()` triggers the actual download/install as a side effect

**A `9999` runner ebuild that curls the vendor's ROLLING install endpoint is a
reproducibility bug, not a convenience.** It installs whatever is published at
merge time, so a broken release cannot be avoided or reverted by re-emerging —
re-emerging is what pulls it in. Measured consequence on this box: repeated
unreliable Ollama updates. Ship a **version-pinned** ebuild instead:

- Fetch the installer **from the release asset**, not the rolling endpoint and
  not `raw.githubusercontent.com`. For Ollama,
  `.../releases/download/v${PV}/install.sh` returns 200 while
  `raw.githubusercontent.com/ollama/ollama/v${PV}/install.sh` is **404** — the
  script is a release asset only, not tracked at that path in the repo tree.
- Pass the version through **whatever env var the installer honours**; discover
  it, don't assume: `grep -nE '\$\{?VENDOR_[A-Z_]+' install.sh`. Ollama's
  `install.sh` appends `?version=$OLLAMA_VERSION` to its Linux download URL and
  `ollama.com` resolves that to the exact release asset, so `OLLAMA_VERSION=${PV}`
  pins the payload.
- Verify the installer against the `sha256sum.txt` published with the SAME
  release and **fail closed** when it is absent, unlisted, or mismatched. State
  what this covers: it pins and verifies the *installer*. If the installer does
  not checksum its payload tarball, payload integrity still rests on HTTPS — say
  so in a comment rather than implying a fully verified chain.
- `pkg_postinst` runs AFTER the package's files are merged, so `die` there
  reports a failure that did not happen. Use `ewarn` plus a re-run hint instead.
- Vendor installers commonly rewrite `/etc/systemd/system/<name>.service`
  **unconditionally**, which SHADOWS the unit `systemd_dounit` installs to
  `/usr/lib/systemd/system/`. Check both knobs before trusting a skip flag: some
  (Ollama's `OLLAMA_NO_START`) are macOS-only and do not gate the Linux unit
  write. Confirm with `systemctl show <unit> -p FragmentPath`.
- Version-specific payload quirks are real: Ollama's Linux path prefers
  `.tar.zst` and falls back to `.tgz`, which is now **404** on new releases — so
  `app-arch/zstd` is a genuine RDEPEND (the installer hard-errors without it),
  and zstd is already present on this box.

#### (b) Full-build Go live ebuild (git-r3 + go-module_live_vendor)

For Go projects that need to compile from source, using git-r3 to fetch and go-module_live_vendor to handle dependencies:

```bash
EAPI=8

inherit git-r3 go-module

DESCRIPTION="..."
HOMEPAGE="https://github.com/org/repo"
EGIT_REPO_URI="https://github.com/org/repo.git"

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS=""
S="${WORKDIR}/${P}"
RESTRICT="mirror"

BDEPEND="
	>=dev-lang/go-1.25:=
"

src_unpack() {
	git-r3_src_unpack
	go-module_live_vendor
}

src_compile() {
	pushd backend > /dev/null || die
	CGO_ENABLED=0 ego build -v -ldflags="-w -s" -o agentrq ./cmd/server/main.go || die
	popd > /dev/null || die
}

src_install() {
	dobin agentrq
}
```

Key patterns:
- `EGIT_REPO_URI` replaces `SRC_URI`; add the same URL to `HOMEPAGE`
- `S` must be set BEFORE `RESTRICT` to satisfy `VariableOrderWrong`
- `go-module_live_vendor` is called in `src_unpack` after `git-r3_src_unpack` — vendors Go module deps at build time, avoiding the need for `EGO_SUM` or a deps tarball
- `KEYWORDS=""` (empty) for live ebuilds — no keywords means testing-only
- Add `RDEPEND` entries for account packages if the binary runs as a dedicated system user (see Account packages section below)

Live ebuilds need the keyword accepted:
```bash
echo "=cat/pkg-9999 ~amd64" | sudo tee -a /etc/portage/package.accept_keywords/pkg
```

### Go + Vue monorepo (multi-stack build)

For projects where a frontend (Vue, React, etc.) builds to static assets served by a Go backend:

```bash
BDEPEND="
	>=dev-lang/go-1.25:=
	>=net-libs/nodejs-20:=
"

src_prepare() {
	default
	# ensure clean frontend build
	rm -rf backend/cmd/server/public || die
}

src_compile() {
	einfo "Building frontend..."
	pushd frontend > /dev/null || die
	npm ci || die
	npm run build || die
	popd > /dev/null || die

	einfo "Building backend..."
	pushd backend > /dev/null || die
	CGO_ENABLED=0 ego build -v -ldflags="-w -s" -o agentrq ./cmd/server/main.go || die
	popd > /dev/null || die
}

src_install() {
	pushd backend > /dev/null || die

	# binary to libexec (wrapper or systemd service controls the runtime path)
	exeinto /usr/libexec/agentrq
	doexe agentrq

	# pre-built frontend assets
	insinto /usr/share/agentrq/public
	doins -r cmd/server/public/.
	fperms 0755 /usr/share/agentrq/public

	# example configs
	insinto /etc/agentrq
	doins cmd/server/_config/base.yaml
	doins cmd/server/_config/production.yaml

	popd > /dev/null || die
}
```

Pitfalls:
- The Go binary is typically `CGO_ENABLED=0` (static binary) — no `DEPEND` needed for C libs
- Frontend build (Node.js in `BDEPEND`) must run BEFORE the Go build so the `public/` dir exists
- If the binary reads config from a relative path (e.g. `./_config/`), install configs to `/etc/pkg/` and use systemd `ExecStartPre` to symlink them into the `WorkingDirectory`
- Use `exeinto /usr/libexec/pkg/` + `doexe` instead of `dobin` when a wrapper or systemd service controls the runtime environment

### Account packages (acct-group / acct-user)

Create these as separate packages when your daemon needs a dedicated system user:

**acct-group/name/name-0.ebuild:**
```bash
EAPI=8
inherit acct-group
DESCRIPTION="System group for appname"
ACCT_GROUP_ID=<gid>
```

**acct-user/name/name-0.ebuild:**
```bash
EAPI=8
inherit acct-user
DESCRIPTION="System user for appname"
ACCT_USER_ID=<uid>
ACCT_USER_GROUPS=( groupname )
ACCT_USER_HOME=/var/lib/appname
```

Pitfalls:
- **Ebuild filename**: directory is `acct-user/name/`, the ebuild file must be `name-0.ebuild` (NOT `acct-user-name-0.ebuild`). The `acct-user` eclass derives the username from `${PN}` — the directory name, not the ebuild filename prefix. Using a `cat-name-0.ebuild` filename triggers a pkgcheck `MismatchedPN` warning.
- Choose GID/UIDs above 499 (system range). Check no conflicts: `find /var/db/repos/gentoo/acct-group -name "*.ebuild" | xargs grep ACCT_GROUP_ID=`
- In the main ebuild, add to `RDEPEND`: `acct-group/name acct-user/name`

### Conditional dependencies

```bash
IUSE="X alsa sdl"
RDEPEND="
    X? ( x11-libs/libX11 )
    alsa? ( media-libs/alsa-lib )
    sdl? ( media-libs/libsdl2 )
    !sdl? ( media-libs/libsdl )
"
```

### Install systemd service

```bash
inherit systemd

src_install() {
    dobin myapp
    systemd_dounit "${FILESDIR}/myapp.service"
    systemd_newunit "${FILESDIR}/myapp@.service" "myapp@.service"
}
```

**PITFALLS IN EAPI 8:**
- Do NOT call `systemd_disable` or `systemd_enable` in `pkg_postinst()` — these functions are not provided by the systemd eclass in current Portage (EAPI 8). They error at runtime with "command not found". Just install the unit with `systemd_dounit` and instruct the user to enable manually.
- Hardcode `User=` home paths in ExecStart — In system units (not user units), `%h` in ExecStart sometimes expands to root's home even with `User=` set. Always use absolute paths: `/home/$user/.config/app/config.xml` instead of `%h/.config/app/config.xml`.
- Set `WorkingDirectory` when the binary uses relative rpath — If bundled libraries resolve via `$ORIGIN`/`$ORIGIN/..`, set `WorkingDirectory=/opt/app` so the cwd matches the install dir.
- Service files go to `/usr/lib/systemd/system/` when installed via `systemd_dounit`.
- For long-running oneshot services (hours), always set `TimeoutSec=21600` or `TimeoutSec=infinity` — systemd's default runtime limit (90s on some configs) kills oneshot services silently. The service log shows "Deactivated successfully" but the command never finished.
- Multiple `ExecStart` lines run sequentially in oneshot services — this IS the right pattern for chaining commands (unlike a shell `&&` which needs a shell invocation). Each line runs in order; the service fails if any line fails.
- Binary AppImage/AppDir packages may produce `Security problem NULL DT_RUNPATH` from `scanelf` — this is the vendor's build, not a packaging defect. It is harmless.

### Python package

```bash
inherit python-single-r1

REQUIRED_USE="${PYTHON_REQUIRED_USE}"
RDEPEND="${PYTHON_DEPS}"
BDEPEND="${PYTHON_DEPS}"
```

## Resources

- [Gentoo Devmanual: ebuild](https://devmanual.gentoo.org/eclass-reference/ebuild/index.html) — full ebuild man page
- [Basic guide to write Gentoo Ebuilds](https://wiki.gentoo.org/wiki/Basic_guide_to_write_Gentoo_Ebuilds) — Gentoo wiki walkthrough
- [Eclass reference](https://devmanual.gentoo.org/eclass-reference/) — all eclasses documented
- [Gentoo Policy Guide](https://projects.gentoo.org/qa/policy-guide/) — QA rules
- [Quickstart Ebuild Guide](https://devmanual.gentoo.org/quickstart/) — quick reference
- [GLEP 68: EAPI 8](https://www.gentoo.org/glep/glep-0068.html)
- [Category list](https://packages.gentoo.org/categories)
- [License list](https://gitweb.gentoo.org/repo/gentoo.git/tree/licenses)

## References in this skill

- `references/ggml-package-pattern.md` — Packaging ggml-derived CMake projects (llama.cpp, CrispASR, whisper.cpp forks): common CMake flags, USE flag mapping, deprecated option migration, CUDA sandbox exceptions.
- `references/network-assets-sandbox.md` — Handling CMake projects that download network assets (npm UI, HF tarballs) at build time: sandbox failure identification, pkg_postinst instructions pattern, CMake flags to disable downloads.
- `references/deb-extraction-binary-ebuild.md` — Creating binary ebuilds from .deb / .rpm sources.
- `references/go-vue-monorepo-agentrq.md` — AgentRQ live ebuild example: git-r3 + go-module_live_vendor + Vue frontend build + acct-group/user + systemd service with ExecStartPre config setup.
