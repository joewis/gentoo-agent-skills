# Localrepo precompiled-binary ebuild — proven pattern

Use this when you need a working localrepo ebuild for a CLI tool that ships
precompiled per-arch binaries (goreleaser output is the most common case —
GoReleaser archives named `${PN}-${os}-${arch}.tar.gz` containing a single
binary plus LICENSE/README/CHANGELOG files).

This is the alternative to a source-build ebuild when:
- The toolchain required by `go.mod` / `package.json` is newer than what's
  in ::gentoo stable (e.g. `go 1.26` required, `dev-lang/go-1.26.x` not in
  tree or unstable)
- The build environment can't reach `proxy.golang.org` / `npmjs.org` to
  fetch deps or auto-toolchains
- The binary is statically linked (`ldd` shows "not a dynamic executable")
  so RDEPEND collapses to nothing
- Upstream's own install method is a one-liner that downloads the same
  precompiled tarball (e.g. RunPod's `wget cli.runpod.net | bash`)

## When to reach for this

Prefer this over a source-build ebuild whenever all of these are true:
- Upstream publishes per-arch binary tarballs as release assets
- The binary is statically linked (no glibc, no bundled `.so`s you need to ship)
- You don't need reproducible-from-source builds

## The pattern (verified working on Gentoo + localrepo, July 2026)

```bash
# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="One-line description"
HOMEPAGE="https://github.com/owner/repo"
SRC_URI="https://github.com/owner/repo/releases/download/v${PV}/reponame-linux-amd64.tar.gz"
S="${WORKDIR}"

LICENSE="<upstream-license-spdx>"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="mirror strip"

src_unpack() {
    default
    # Upstream tarball extracts a flat binary at the top level. Rename so:
    #   1. The install phase can target it unambiguously
    #   2. einstalldocs doesn't try to install a non-doc file
    mv reponame reponame-bin 2>/dev/null || die "reponame binary not found in archive"
}

src_install() {
    newbin reponame-bin reponame
    dodoc LICENSE README.md CHANGELOG.md
}

pkg_postinst() {
    elog "..."
}
```

## Why each piece is there

| Line | Why |
|---|---|
| `RESTRICT="mirror strip"` | Don't re-mirror the upstream release asset (it's an unstable URL anyway), don't re-strip the binary (already stripped, double-strip breaks ELF) |
| `KEYWORDS="~amd64"` | Start conservative; bump to `amd64` after testing |
| `S="${WORKDIR}"` | Tarball extracts to top level, no versioned subdir |
| `src_unpack` rename | Prevents `einstalldocs` from choking on a non-doc file in `S`; makes install explicit |
| `newbin src dst` | Installs `src` as `/usr/bin/dst` with correct mode/owner |
| Explicit `dodoc` | `einstalldocs` in EAPI 8 only installs `README*` by default. `LICENSE` and `CHANGELOG.md` need explicit listing. |
| `pkg_postinst` with `elog` | First-run hint visible in `emerge` output |

## Deployment steps (localrepo)

```bash
# 1. Stage the files (write them to /tmp first because hermes file tools
#    can't write into portage:portage-owned directories)
sudo mkdir -p /var/db/repos/localrepo/app-misc/reponame
sudo cp /tmp/reponame-X.Y.Z.ebuild /var/db/repos/localrepo/app-misc/reponame/
sudo cp /tmp/metadata.xml          /var/db/repos/localrepo/app-misc/reponame/
sudo chown -R portage:portage /var/db/repos/localrepo/app-misc/reponame

# 2. Generate the Manifest (downloads + hashes)
cd /var/db/repos/localrepo/app-misc/reponame
sudo -u portage pkgdev manifest

# 3. QA scan
sudo -u portage pkgcheck scan

# 4. Full ebuild test (must be root — see pitfall #2 below)
sudo ebuild ./reponame-X.Y.Z.ebuild clean test install

# 5. Smoke test
sudo /var/tmp/portage/app-misc/reponame-X.Y.Z/image/usr/bin/reponame --version

# 6. Commit to localrepo git
cd /var/db/repos/localrepo
sudo -u portage git add app-misc/reponame/
sudo -u portage git -c user.name=... -c user.email=... commit -m "app-misc/reponame: add X.Y.Z"

# 7. Install on the host
sudo emerge --ask --verbose =app-misc/reponame-X.Y.Z
```

## Known pitfalls (read these before you start)

### Pitfall 1: `RDEPEND=""` triggers `EmptyGlobalAssignment`

```
empty global assignment: RDEPEND=""
```

Don't write `RDEPEND=""` in your ebuild. Just omit the line entirely.
pkgcheck flags the explicit-empty assignment; an absent `RDEPEND` is
fine for static binaries with no runtime deps.

### Pitfall 2: `ebuild` install phase needs root

```
install: cannot change ownership ... Operation not permitted
 * ERROR: app-misc/<pkg>::localrepo failed (install phase):
 *   dobin failed
```

Running `ebuild ... install` as a non-root user (even `sudo -u portage`)
fails because the install phase calls `chown` on the image dir and only
root has `CAP_CHOWN` on `/var/tmp`. Run the **install phase as root**.
The other phases (`manifest`, `pkgcheck`, `unpack`, `compile`, `test`)
work fine as the `portage` user.

### Pitfall 3: `hermes` file-write tools can't write into `portage:portage` dirs

```
Failed to write file: /usr/bin/bash: line 3: .../.hermes-tmp.NNNNN: Permission denied
```

The `write_file` / `patch` / `read_file` tools run as your agent user
(e.g. `carl`, uid 1001), not as `portage`. They can't create files in
`/var/db/repos/localrepo/...` because the perms are sticky. Workaround:
write the ebuild to `/tmp/` and `sudo cp` it into place, then
`sudo chown portage:portage` the file.

### Pitfall 4: Don't put vendored deps in `files/`

```
SizeViolation: 'files/<pkg>-<ver>-vendor.tar.xz' exceeds 20.0 KiB in size; 1.6 MiB total
TotalSizeViolation: files/ directory exceeds 50.0 KiB in size; 1.6 MiB total
MissingUri: unfetchable file: '<pkg>-<ver>-vendor.tar.xz'
```

The `files/` directory next to an ebuild has a **20 KB per-file / 50 KB
total** limit enforced by pkgcheck. Vendor tarballs are bigger than that.
For Go source builds with vendored deps in a localrepo, you need a proper
distfile mirror setup (`metadata/layout.conf` + `file://` mirror in
`repos.conf`). For the simpler precompiled-binary pattern, you don't need
this at all.

### Pitfall 5: The tarball URL can change

Upstream's goreleaser config might rename the archive between releases.
When bumping, `pkgdev manifest` will fail to fetch with a 404 — look at
the latest release's assets on GitHub to see if the naming pattern shifted.
Common patterns:
- `name-os-arch.tar.gz` (most common)
- `name_version_os_arch.tar.gz`
- `name-os-arch-upx.tar.gz` (when goreleaser compresses)
- `name_darwin_all.tar.gz` (universal Mac binary)

### Pitfall 6: `einstalldocs` doesn't install LICENSE/CHANGELOG

```
# only this shows up after src_install:
-rw-r--r-- 1 root root 1475 Jul 13 09:23 README.md.bz2
# where's LICENSE? CHANGELOG?
```

Unlike older EAPI defaults, `einstalldocs` in EAPI 8 only matches
`README*`. If you want LICENSE and CHANGELOG.md in
`/usr/share/doc/${PF}/`, you must use `dodoc LICENSE README.md CHANGELOG.md`
explicitly. Replace `einstalldocs` with `dodoc` in your `src_install()`.

### Pitfall 7: Static binary still wants `strip` in RESTRICT

The precompiled binary is already stripped (`file` reports
`BuildID[sha1]=...` and `stripped`). If you don't add `RESTRICT="... strip"`,
Portage's `prepstrip` step will run and either silently no-op or break the
binary on some configs. The `strip` in RESTRICT tells Portage to skip
the strip pass — it's mandatory, not optional, for precompiled ebuilds.

### Pitfall 8: `go.mod` says `>=go 1.26.4` but ::gentoo has only `1.26.4` and `1.25.x`

Even when the exact required version is in tree, an `auto` toolchain
strategy may try to fetch a newer version over `proxy.golang.org`. If
that proxy is unreachable (firewall, no internet for the build user),
the build will silently hang or fail with `TLS handshake timeout`. The
fix is to ensure `>=dev-lang/go-1.26:=` is in BDEPEND AND the user has
the exact version installed locally — don't rely on `GOTOOLCHAIN=auto`.

For static binaries this is moot (no Go toolchain needed at all). For
source builds, pin to the exact version available in the local portage
tree.

## Worked example: app-misc/runpodctl-2.6.1

A real-world shipped ebuild using this pattern, end-to-end (Gentoo
localrepo, July 2026):

- **Ebuild:** 22 lines
- **Manifest:** 1 distfile (`runpodctl-linux-amd64.tar.gz`, 5.3 MB)
- **Build:** zero (binary only)
- **Installed:**
  - `/usr/bin/runpodctl` (13.7 MB, root:root, 0755)
  - `/usr/share/doc/runpodctl-2.6.1/{LICENSE,README.md,CHANGELOG.md}.bz2`
- **Smoke test:** `runpodctl --version` returns `runpodctl 2.6.1-32e9aec`
- **Committed to localrepo git:** commit `3826b30`
- **All pkgcheck warnings:** zero
- **ebuild test phases:** all green

The original attempt was a Go source-build with `go-module` eclass +
vendored deps. It was abandoned mid-debug when **two** independent walls
hit at once:
1. `proxy.golang.org` returned `TLS handshake timeout` (unreachable from
   this host)
2. `dev-lang/go-1.26.5` was not yet in ::gentoo (only `1.26.4` was
   stable, and 1.26.5 was needed per `go.mod`)

The pivot to precompiled-binary took ~15 minutes from "decision" to
"committed and tested", versus a multi-day slog on the source build.
The user's signal that triggered the pivot: "just find a way, continue.
keep it simple, if possible".

## When this pattern is NOT enough

- **Multi-arch binary ebuilds** (amd64 + arm64 + ...): you need separate
  per-arch `SRC_URI` blocks guarded by `KEYWORDS`, or a `MULTILIB` setup.
- **Binaries with bundled .so files** (proprietary GUI apps): need
  `insinto /opt/appname` + `fperms` on every executable. See the
  "Precompiled binary package" section in the parent `write-ebuild` skill.
- **Snapshot/auto-updating binaries** (Ollama-style): use the live ebuild
  pattern with `RESTRICT="mirror"` and `pkg_postinst` doing the actual
  download.

## Verifying a precompiled-binary ebuild (acceptance checklist)

After running `sudo ebuild ... clean test install`, walk this list:

- [ ] `/var/tmp/portage/<cat>/<pkg>-<ver>/image/usr/bin/<bin>` exists, mode 0755, owner root:root
- [ ] `/var/tmp/portage/<cat>/<pkg>-<ver>/image/usr/share/doc/<pkg>-<ver>/` contains LICENSE, README, CHANGELOG
- [ ] `sudo <image>/usr/bin/<bin> --version` returns sensible output
- [ ] `ldd <image>/usr/bin/<bin>` shows `not a dynamic executable` OR only system libs
- [ ] `file <image>/usr/bin/<bin>` shows `statically linked` (good) or `dynamically linked` with sane deps (ok for precompiled)
- [ ] `sudo -u portage pkgcheck scan` from the ebuild dir returns exit 0 with no warnings
- [ ] `Manifest` has both BLAKE2B and SHA512 hashes for every `DIST` entry
- [ ] `git log` shows the ebuild + metadata.xml + Manifest committed together
