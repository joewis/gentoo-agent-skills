# AppImage Binary Ebuild Pattern

For applications distributed as AppImages (Electron apps, single-file
self-mounting executables with embedded squashfs payload).

## Rationale

AppImages bundle their own libraries and runtime. Rather than trying to
extract the binary and its deps manually, let the AppImage runtime extract
itself during `src_compile` via `--appimage-extract`, then install the
resulting `squashfs-root/` tree to `/opt/`.

## Full example: Obsidian

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit desktop

DESCRIPTION="Obsidian — powerful knowledge base on top of local plain text Markdown files"
HOMEPAGE="https://obsidian.md/"
SRC_URI="https://github.com/obsidianmd/obsidian-releases/releases/download/v${PV}/Obsidian-${PV}.AppImage"

S="${WORKDIR}"
LICENSE="all-rights-reserved"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="bindist mirror strip"

RDEPEND="
	sys-fs/fuse
	sys-libs/glibc
"

src_unpack() {
	cp "${DISTDIR}/Obsidian-${PV}.AppImage" "${S}/" || die
}

src_compile() {
	chmod +x "${S}/Obsidian-${PV}.AppImage" || die
	"${S}/Obsidian-${PV}.AppImage" --appimage-extract >/dev/null 2>&1 || die "extraction failed"
}

src_install() {
	insinto /opt/obsidian
	doins -r "${S}/squashfs-root/"* || die
	fperms 0755 /opt/obsidian/obsidian

	cat > "${T}/obsidian" <<- 'WRAPPER' || die
	#!/usr/bin/env bash
	exec /opt/obsidian/obsidian "${@}"
	WRAPPER
	dobin "${T}/obsidian"

	if [[ -f "${S}/squashfs-root/obsidian.desktop" ]]; then
		domenu "${S}/squashfs-root/obsidian.desktop"
	fi

	local icon
	for icon in "${S}/squashfs-root/"*.png "${S}/squashfs-root/"*.svg; do
		if [[ -f "${icon}" ]]; then
			newicon "${icon}" "$(basename "${icon}")"
			break
		fi
	done
}
```

## Key patterns

- `inherit desktop` is required for `domenu` and `newicon`. Without it,
  pkgcheck flags `MissingInherits`.
- `--appimage-extract` unpacks the squashfs payload into `squashfs-root/`.
  Suppress stdout or the build log is flooded with file listings.
- `fperms 0755` is needed after `doins -r` because `doins` does not
  preserve executable bits on the main binary.
- Install the extracted tree to `/opt/<pkgname>` and create a `/usr/bin/`
  wrapper script.
- Desktop entry and icons, if present in the AppImage, should be installed
  for GUI integration.
- `RESTRICT="bindist mirror strip"` — AppImages contain precompiled
  binaries; do not strip them or create redistributable packages.
- `sys-fs/fuse` is needed at runtime (the AppImage runtime uses FUSE even
  for extraction).
- QA will likely flag `NonsolvableDepsInDev` for `glibc` on musl profiles
  — expected and harmless for glibc-linked binaries.

## Testing

```bash
cd /var/db/repos/localrepo/app-misc/obsidian
sudo pkgdev manifest
pkgcheck scan
sudo ebuild ./obsidian-1.13.7.ebuild clean test install
```

Verify extraction produced a runnable binary:
```bash
ls /var/tmp/portage/app-misc/obsidian-1.13.7/image/opt/obsidian/obsidian
/var/tmp/portage/app-misc/obsidian-1.13.7/image/usr/bin/obsidian --help
```

## Pitfalls

- **Silent extraction failure** — if `--appimage-extract` fails, it may
  return a non-zero exit but the error is hidden by stdout suppression.
  Always `|| die` the extraction command.
- **Wrong `S` variable** — default `S="${WORKDIR}/${P}"` is wrong because
  there's no tarball that extracts to a versioned directory. The AppImage
  is a single file; set `S="${WORKDIR}"` explicitly.
- **Desktop entry path** — the `.desktop` file inside the AppImage may
  reference relative paths or the bundled binary path. If it doesn't work
  after install, patch it in `src_install` with `sed` to point at `/opt/`.
- **Icon names** — upstream may use generic icon names. Use `newicon` with
  an explicit destination name to avoid conflicts.
