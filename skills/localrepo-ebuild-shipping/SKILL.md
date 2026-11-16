---
name: localrepo-ebuild-shipping
description: "End-to-end workflow for shipping an ebuild to a Gentoo localrepo overlay — pkgcheck pitfalls, the portage:portage permission model, the manifest→QA→test→install→commit pipeline, and the source-build-vs-binary ebuild decision. Triggers when the user asks to package, ebuild, portage, emerge, localrepo, overlay, add to localrepo, install custom package, or says 'write an ebuild for X' for a package not in ::gentoo."
---

# Shipping an ebuild to a Gentoo localrepo

The full operational workflow for going from "I want to package X" to "X is
in my localrepo, committed to git, installable via `emerge`". Complements
the generic `write-ebuild` skill (which covers ebuild syntax/structure) by
covering the **localrepo-specific operational layer** that bites you when
you try to actually ship one.

## ⚠️ Portage packaging is the default install method on this box

The user corrected this explicitly (2026-09-13): when asked to install or make
software available system-wide on this Gentoo host, the expected route is an
**ebuild in the localrepo + emerge** — NOT a pip install into `/opt`, NOT a
tar-copy of someone's `~/.local/share/uv/tools` venv, NOT a symlink into
`/usr/local/bin`. Those ad-hoc patterns were all tried first for graphifyy and
all rejected. Route: check ::gentoo and ::guru first (`emerge -s`, `eix`); if
absent, write the ebuild (see `references/pypi-wheel-bundling-ebuild.md` for
PyPI packages with unbundleable deps) and ship it through the pipeline below.
The resulting package is then managed by Portage (`emerge -C`, world file,
version bumps) like everything else on the system.

### Long-term tools get an ebuild; `/usr/local/bin` is for ad-hoc use only

A tool the user wants **for the long term** gets packaged — this is the shape of
the request even when it is phrased as "install X" or "make X available". Loose
files in `/usr/local/bin` are for ad-hoc, one-off, or not-yet-decided use.

**The mechanism behind the objection is removal cost, not tidiness.** An
unmanaged file is forgotten as soon as it is written and the bill arrives later:
working out what depends on ~27 accumulated entries took ten greps of archaeology
and still turned up residues nobody remembered creating — byte-identical
duplicates, a superseded binary already backed up elsewhere, a probe for a
finished job. A packaged file carries its own reverse-dependency answer
(`equery depends`, its CONTENTS entry, `emerge -C`), so that work is already done.

**`/usr/local/bin` is the FHS local-admin area, so Portage manages ZERO files
there by design** — `grep -c '^/usr/local' /var/db/pkg/*/*/CONTENTS` returns 0.
"Only portage-managed files in `/usr/local/bin`" is therefore unsatisfiable; the
standard that is actually meaningful is *npm-managed, or a deliberately placed
local file whose owner and purpose are known*.

**Before writing into `/usr/local/bin`, test whether it must be system-wide.**
Only these cases justify it; everything else belongs in `~/.local/bin`, which is
already first on `$PATH`:

- a systemd unit runs it as **another user** (`ollama`, unit `User=ollama`;
  root-run `qmd-watch.sh` / `xvfb-openbox.sh`)
- another **agent user** must execute it — `caption`, `piper-*`, `apinav` — and
  `/home/carl` is mode `700`, so `~/.local/bin` is unreadable to them
- it is a symlink into a package manager's own tree (`openclaw` →
  `/usr/lib64/node_modules/…`)

A wrapper script for a tool **you** call is none of those: put it in
`~/.local/bin`.

## Auditing what Portage manages (ownership is a different question)

When asked what Portage **manages**, or which files are unmanaged, do not run
`qfile <path>` and report the answer — that answers *ownership* (which package's
CONTENTS lists this file), which is a different question and reads as a
non-answer. The user distinguishes the two explicitly; use the right command for
the question asked.

| question | command |
|---|---|
| which files are **unmanaged** (orphans) | `qfile --orphans <files...>` |
| which package **owns** one file | `portageq owners / <path>` (or `qfile <path>`) |
| which files a package **manages** | `portageq contents / <cat>/<pkg>` / `qlist -e <pkg>` |
| package integrity | `qcheck <cat>/<pkg>` |
| repo / world health | `emaint all` |

Two traps:

- **`qfile --orphans` needs the FILES passed explicitly.** Pointed at a directory
  alone it returns only that directory (`qfile --orphans -d /dir` returns
  nothing). Use `qfile --orphans /usr/local/bin/*`.
- **`qfile` only knows Portage, so every npm-installed file reports as an
  orphan.** Follow the scan with a second pass against `npm root -g` before
  calling a file unmanaged.

The managed set itself is `/var/db/pkg/*/*/CONTENTS`; counting entries under a
path is the fastest way to prove a tree sits entirely outside Portage
(`grep -c '^/usr/local' /var/db/pkg/*/*/CONTENTS` → 0).

### "Is it installed?" is a package question — never answer it from a hardcoded path

Code that pins an absolute path to a helper binary (`CAMOFOX = "/home/<user>/.local/bin/camofox"`)
tells you where the *author* expected it, not where it is. The package may ship it somewhere else
entirely (`app-misc/camofox` installs `/usr/bin/camofox`). **A missing file at the pinned path is
then a stale constant in the code, not an absent package** — and reporting "X is not installed"
from that evidence invents a blocker and sends the next session rebuilding something that already
exists.

Check state from the package database and the live PATH, in that order:

```bash
qlist -I <pkg>        # installed? (ask by NAME — any package providing it)
qfile <path>          # which package owns this path
command -v <tool>     # what actually resolves on PATH right now
```

When the pinned path and the packaged path disagree, report the two findings separately —
*"the tool is packaged at `<real path>`; the code pins a path that does not exist"* — and the fix
is to resolve from `PATH`, not to install anything. An audit of "what still needs packaging"
yields a wrong work list if any entry is derived from a path instead of from the package DB.

## Can this tool be packaged at all? (check BEFORE promising the route)

Packaging assumes there is something fetchable and pinnable. Check these in order —
each failure is either a work item or a blocker, and discovering it mid-pipeline is expensive.
The output of this check is the work list, so give it before agreeing the tool is packageable.

0. **Is it ALREADY packaged — by you?** Look before you plan. This is the cheapest check and the
   most embarrassing miss: proposing an ebuild for something that already has one in localrepo,
   or proposing to invent a convention this box already implements, reads as not having looked
   at your own work.
   ```bash
   ls /var/db/repos/localrepo/<cat>/            # does the package dir exist?
   qlist -Iv <pkg>                             # installed from where?
   grep -rl "<the pattern you are about to invent>" /var/db/repos/localrepo/*/*/
   ```
   The same applies to **patterns, not just packages**: before proposing a mechanism (a service
   account, a unit, a config layout), grep the localrepo for an existing instance and follow it.
   A convention already implemented on this box is the specification; re-inventing it produces a
   second, divergent one. Read the existing ebuild's `src_install` to see exactly what it ships —
   that is also how you learn which files are deliberately *not* package-managed.

1. **Is there a public upstream to pin?** `SRC_URI` needs a tag, a release asset, or a commit
tarball. A tool that exists only as loose files in an operator's home (`~/mcp-servers/`,
`~/x380-mcp/`) is **not packageable as-is** — no remote, no history, nothing to hash. Pushing
it to GitHub is the prerequisite, not part of the ebuild.
   ```bash
   gh api repos/<owner>/<repo>/tags --jq '.[].name'   # empty → pin a commit hash instead
   git -C <dir> remote -v                            # no remote → not packageable yet
   ```
   No tags is not a blocker, just a choice: pin `archive/<sha>.tar.gz`, or cut a first tag so
the ebuild matches the `${PV}` convention every other localrepo package uses.
2. **Is the license redistributable?** MIT/Apache → plain ebuild. Source-available (PolyForm,
BUSL, custom EULA) → still shippable, but needs the license-file plus
`RESTRICT="mirror strip bindist"` dance; see the non-standard-licenses section.
3. **Are the runtime deps in `::gentoo`?** Check each one individually — this decides the
shape of the ebuild. Missing pure-Python deps → prepared-bundle venv (the xiaomi-devices
pattern); Node → prepared runtime bundle. Do not assume: the `mcp` Python SDK is **not** in
`::gentoo`, while numpy and pyyaml are.

   **Derive the dep list from IMPORTS, never from the size of the tool's venv.** A working
   venv holds the full transitive closure (102 packages is normal) while the *direct* import
   set is often a handful — and nearly all of it in-tree. Planning a wheel bundle from the
   venv size over-scopes the work badly. Run `scripts/backend_dep_audit.py <tool dirs...>`
   (AST-based, stdlib subtracted) to get the distinct third-party imports and an in-tree
   verdict for each; the short list of misses is your actual work list.

   The corollary saves the most time: when most deps ARE in-tree, the ebuild is a plain
   `RDEPEND` source build and the whole prepared-bundle apparatus (release asset, pre-seeded
   `$DISTDIR`, `licenses.txt`) is unnecessary. Check before promising that shape.
4. **Does the code hardcode paths into the operator's home?** Grep for it, and read the config
defaults, not just the config file. Defaults like `ENV_FILE = /home/<user>/.hermes/.env` or
`DB_PATH = /home/<user>/<tool>/catalog.db` mean the package will not work for any other user
— and a packaged service cannot read them at all, because `/home/<operator>` is mode `700`.
Fixing this is an **upstream change** (make the paths XDG- or prefix-relative), not something
the ebuild can paper over. Surface it before starting, not after the manifest is generated.
5. **Is the large data runtime state or shipped content?** A multi-GB catalog or index built by
the tool's own ingest step is **state**: the ebuild installs code only, and the rebuild path
must be documented in `pkg_postinst`. Confirm the ingest can run offline before claiming the
package is usable.
6. **Is it SITE-SPECIFIC — does it encode this LAN, these devices, or this deployment's internals?**
A tool can be a clean public repo, permissively licensed and pure Python, and still be a
**non-candidate**. If its purpose is to reach a particular machine on a particular network (a GPU
node on the LAN, a router's reverse-engineered admin API, an internal task queue), packaging it
yields a package that means nothing anywhere else — that is configuration, not distributable
software. Keep it local and relocate it to a shared tree if a service account must reach it; do not
ebuild it. Judge by **what the tool talks to**, not by how packageable its code looks.

Report which of the seven a given tool fails — that list is the work list. For most
not-yet-packaged tools, item 1 or item 4 is the real blocker, and item 4 is also the one that
blocks any move to a dedicated service account.

## The pipeline (always this order)

1. **Decide source vs binary** (see decision rule below)
2. **Write the ebuild** to `/tmp/<pkg>-<ver>.ebuild` (NOT into the localrepo
   directly — see "Permission model" pitfall)
3. **Write `metadata.xml`** with `<remote-id>` and a valid `<maintainer>` email
4. **Stage into localrepo** via `sudo cp` + `sudo chown portage:portage`
5. **Generate Manifest**: `sudo -u portage pkgdev manifest`
6. **QA scan**: `sudo -u portage pkgcheck scan` — must be exit 0 with no warnings
7. **Full ebuild test**: `sudo ebuild ./<pkg>-<ver>.ebuild clean test install`
   (install phase MUST run as root, others as `portage`)
8. **Smoke test the installed binary** in the image dir
9. **Commit to localrepo git**
10. **Install on host**: `sudo emerge --ask --verbose =<cat>/<pkg>-<ver>`

    **Keyword acceptance:** localrepo packages with `~amd64` keywords need to be accepted. On this system, the convention is to add them to `/etc/portage/package.accept_keywords/zz-localrepo` (the `zz-` prefix ensures it loads last, avoiding conflicts with other keyword files):
    ```bash
    echo "=<cat>/<pkg>-<ver> ~amd64" | sudo tee -a /etc/portage/package.accept_keywords/zz-localrepo
    ```

    Then emerge normally:
    ```bash
    sudo emerge -v =<cat>/<pkg>-<ver>
    ```

    Do NOT use `--ask`/`-a` in non-interactive contexts — it requires a TTY and exits immediately.

Skip any step and you'll regret it later.

## Bumping an existing ebuild to a new version

When you add a new version of a package already in the localrepo (e.g.
`fdc-1.0.0` → `fdc-1.1.0`), the pipeline is the same but with two
version-specific gotchas:

1. **The accept_keywords pin is version-locked.** The convention on this
   box is `=cat/pkg-<ver> ~amd64` in `zz-localrepo` — a *specific* version,
   not a bare `cat/pkg`. So a new version is masked by `~amd64` until you
   update the pin. `emerge -pv =cat/pkg-<newver>` will report
   `masked by: ~amd64 keyword`. Fix:
   ```bash
   sudo sed -i 's/=cat\/pkg-<oldver>/=cat\/pkg-<newver>/' /etc/portage/package.accept_keywords/zz-localrepo
   ```
   Then re-run `emerge -pv` to confirm it resolves before emerging.

2. **Re-emerge clobbers config files — keep the user's real value.**
   If the ebuild installs a config file (e.g. `/etc/fdc/api_key`), the
   re-emerge writes the new default as `._cfg0000_<file>` and warns
   `config file '/etc/fdc/api_key' needs updating`. If the user has a real
   value in that file (a real API key, not the `DEMO_KEY` default), you
   MUST keep the existing file and discard the cfg update:
   ```bash
   sudo rm -f /etc/fdc/._cfg0000_api_key   # keep the real key
   ```
   Do NOT run `dispatch-conf`/`etc-update` blindly here — it would replace
   the real key with the packaged default. Check the diff first
   (`sudo cat /etc/fdc/._cfg0000_*`) and only accept if the change is
   actually wanted.

3. **Bump the version in the ebuild filename** (`fdc-1.1.0.ebuild`), copy
   the updated script into `files/`, and `chown portage:portage` both. The
   old version ebuild can stay in the tree (Portage slots by version) or be
   removed once the new one is verified.

### Revision bumps (`-r1`) and the accept_keywords wildcard

A **revision bump** (same upstream version, changed ebuild — e.g. adding a
`files/` script via `newbin`) is a *different CPV* from the base version.
The version-locked pin `=cat/pkg-1.9.2 ~amd64` does **NOT** match
`cat/pkg-1.9.2-r1`, so the new revision is masked by `~amd64` and `emerge`
fails with `All ebuilds that could satisfy "=cat/pkg-1.9.2-r1" have been
masked`. Fix by widening the pin to a wildcard so it covers all revisions
of that version:
```bash
sudo sed -i 's/=cat\/pkg-1.9.2 /=cat\/pkg-1.9.2* /' /etc/portage/package.accept_keywords/zz-localrepo
```
Then re-run `emerge -pv =cat/pkg-1.9.2-r1` to confirm it resolves before
emerging. (A bare `cat/pkg` with no `=` would also work but is broader
than the box's convention of version-locked pins.)

When the revision adds a `files/` script, remember the `files/` dir is
`root:root` after `sudo mkdir` — `chown portage:portage` the script too,
and regenerate the Manifest (`sudo ebuild ./<pkg>-<ver>-r1.ebuild manifest`)
so the new ebuild is picked up.

## Checking localrepo freshness against UPSTREAM (not the local tree)

`eix <pkg>` on a localrepo package is **circular and blind to upstream**. The
localrepo ebuilds *are* the definition of "available" — so "installed == latest
available" just confirms the installed version matches one of your own ebuilds.
It can never detect that upstream shipped a newer release, because that version
isn't in the local index. This is a tautology, not a freshness check.

**The real check is against upstream** — GitHub releases/tags or PyPI, per
package. For GitHub-hosted packages:
```bash
curl -s "https://api.github.com/repos/<owner>/<repo>/releases/latest" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name'))"
```
For PyPI packages: `curl -s "https://pypi.org/pypi/<name>/json"` → `d['info']['version']`.

**Before bumping, verify the package actually tracks upstream.** A localrepo
package may be a **hand-maintained custom script** (e.g. `app-misc/fdc` — a
local `fdc.py` wrapper in `files/`, versioned by its own script, no upstream
tarball). Comparing its version against an unrelated PyPI package of the same
name is a **false positive**. Check the ebuild: if it has no `SRC_URI` and the
code lives in `files/`, it's a custom script — skip it. Only bump packages whose
`SRC_URI` points at a real upstream release.

**Version-scheme drift:** upstream may have moved from semver tags to build tags
(whisper.cpp `v1.9.x` → `bNNNN`; llama.cpp `bNNNN`). Match the ebuild's existing
scheme — if it uses `v${PV}`, bump to the latest semver tag, not the build tag.

## Bumping a localrepo ebuild to a new upstream version

The pipeline is the same as adding a new version (manifest → pkgcheck → ebuild
test → smoke → commit), with these version-specific traps:

### Stale-distfile trap (versionless SRC_URI basenames)

If `SRC_URI`'s basename has **no version** (e.g. `runpodctl-linux-amd64.tar.gz`
instead of `runpodctl-2.12.0.tar.gz`), the Manifest hash points at the **old
cached binary** — the new ebuild "builds" but installs the previous version.
Smoke test catches it (`runpodctl --version` → old version). Fix:
```bash
sudo rm -f /var/cache/distfiles/<basename>          # purge stale distfile
sudo rm -f /var/db/repos/localrepo/<cat>/<pkg>/Manifest   # purge stale manifest
sudo -u portage pkgdev manifest                      # re-fetch + re-hash
```
Then re-run the full ebuild test and re-smoke-test. Verify the new Manifest
size differs from the old (a changed byte count confirms a new artifact).

**Why the manual purge is necessary: `pkgdev manifest` does not detect a changed
artifact by itself.** It can report the manifest is already up to date — or exit 0 having written
nothing — while the Manifest keeps the OLD hash and size, since a Manifest that exists is not
re-examined against the distfile. So **any time the bytes behind a `SRC_URI` change while the
filename stays the same, delete the Manifest and regenerate rather than trusting the exit code**,
then compare the Manifest's SHA512 against `sha512sum <distfile>` directly. Two common causes:
a **rewritten upstream tag** (the tarball at `refs/tags/vX` is generated from the new commit, so
its bytes differ while its URL and name do not), and a **re-uploaded release asset** (`--clobber`
keeps the same asset name). Both leave `SRC_URI` looking unchanged.

### pip-wheel `.data/data` sandbox violation (piper-tts 1.8.0 case)

A wheel that ships a `.data/data/<file>` (e.g. `COPYING`) makes pip install that
file to the **real prefix root** (`/usr/COPYING`) **ignoring `--root`**, which
trips the sandbox (`Permission denied: /usr/COPYING`). Two attempted fixes that
DON'T work:
- `addpredict /usr/COPYING` — pip still resolves to the real path and fails.
- Stripping the file from the wheel — pip reads `RECORD` and still tries to
  install it.

**Working fix: unzip the wheel manually into the image dir** instead of using
pip. Map `.data/data/*` to `${D}/usr/`, skip the offending file, preserve modes
from `external_attr`. See the piper-tts 1.8.0 ebuild for the full `src_install`
pattern. (The old 1.4.2 wheel lacked the `.data/data` file, so the pip-based
ebuild worked — the trap appears on a version bump.)

### Go toolchain drift on live (`-9999`) ebuilds

A live ebuild tracks upstream `main`, which can move its `go.mod` requirement
past the installed Go (`go: go.mod requires go >= 1.26.7 (running go 1.26.5;
GOTOOLCHAIN=local)`). The ebuild's `BDEPEND` (e.g. `>=dev-lang/go-1.25.0`) is
satisfied, so portage thinks deps are met, but the live source has moved on.
Fix: bump Go to the required version (`ACCEPT_KEYWORDS="~amd64" emerge --oneshot
'=dev-lang/go-<ver>'`), then rebuild. This is the strongest argument for
**versioned ebuilds over 9999** — a versioned ebuild pins the toolchain
requirement to a known-good point.

## A `9999` ebuild silently SHADOWS a versioned one (`RedundantVersion`)

Adding a versioned ebuild alongside an existing `9999` live ebuild of the same
package does **not** mean the version you pinned is the one that gets merged.
`9999` is the highest version, so it wins the slot, and pkgcheck reports:

```
RedundantVersion: version 0.35.1: slot(0) keywords are overshadowed by version: 9999
```

Consequence: a version pin in `SRC_URI`/`pkg_postinst` is **inert** — emerge still
resolves `9999`, and every merge reinstalls latest. This is easy to miss because
the ebuild tests green on its own. When replacing a live ebuild with a pinned one,
**delete the `9999`** (`sudo git rm <cat>/<pkg>/<pkg>-9999.ebuild` — use the path
relative to the repo ROOT, not the package dir, or git silently matches nothing and
reports success). Removing it also clears any pre-existing warnings it carried.

Confirm the fix by re-running `pkgcheck scan` (the `RedundantVersion` and the
`9999` warnings disappear) and `emerge -pv =cat/pkg-<ver>` (resolves instead of
reporting `masked by: ~amd64 keyword`).

## Testing an ebuild whose `pkg_postinst` does the real install

`ebuild <file> clean test install` runs **only up to `src_install`** — the man
page is explicit that `postinst` is a *separate* target, and `install` just
populates `${D}`. So for a runner ebuild where `pkg_postinst` performs a live
vendor install, the standard dry-run is safe and will NOT touch the running
system. Only `emerge` (via `qmerge`) fires `pkg_postinst`.

This makes it safe to verify the full pipeline with the real system untouched:
assert the image contains exactly the expected files (`find ${D} -type f -o -type l`)
and, afterwards, that the live binary's version, mtime and service state are
unchanged. `ebuild ... install` failing on `die "... failed"` is a false alarm;
check the phase rather than assuming the install broke.

## Source-build vs precompiled-binary decision

This is the first call, made before writing any ebuild:

| Question | Source build | Precompiled binary |
|---|---|---|
| Is `go.mod`/`package.json` toolchain in ::gentoo stable? | ✅ yes | ❌ no → binary |
| Can the build host reach `proxy.golang.org` / `npmjs.org`? | ✅ yes | ❌ no → binary |
| Is the upstream project a CLI tool that ships per-arch binaries? | ❌ no | ✅ yes (goreleaser, manual `make release`) |
| Does the user want reproducible-from-source? | ✅ yes | ❌ no → binary |
| Is the binary statically linked? (`ldd` → "not a dynamic executable") | n/a | ✅ yes → strong signal to go binary |
| Does upstream's own install method download a precompiled tarball? | ❌ no | ✅ yes → strong signal |

**Default rule:** if upstream publishes precompiled binaries and at least
one of the first two rows fails, **go binary**. It's what the project's
own install script usually does, it's simpler, and you avoid a long debug
session on a Go toolchain mismatch.

**Pivot mid-build:** if you start with source-build and hit a wall (toolchain
unavailable, dep proxy unreachable, build error you can't reproduce), don't
grind through — switch to the binary pattern and keep moving. The user
cares about a working ebuild, not which approach you started with. Document
the pivot in your reply so the choice is auditable.

## Node/TypeScript packages (there is no npm eclass)

`::gentoo` ships **no npm eclass** — check before promising a source build
(`ls /var/db/repos/gentoo/eclass/ | grep -i npm`; if ::guru isn't installed there is no
borrowed one either). Without it there is no supported way to resolve an npm dependency tree
inside the sandbox, so a “source” ebuild degenerates into `npm ci` from the network on every
merge (`RESTRICT="network-sandbox"`), plus the project's `prepare` hook and native
postinstalls running during install. None of that buys reproducibility the pinned bundle hash
does not already give.

**Ship a prepared runtime bundle instead**, attached as a release asset on the same repo the
ebuild points at, so `SRC_URI` still points where it should:

1. **Assemble what ships at runtime** from a working tree: `dist/`, `bin/`, `package.json`,
   licence/docs, `node_modules`, plus any `skills/` or `scripts/` dirs the published package
   includes. Copying the prod dependency tree from a working install beats re-resolving it.
2. **Build the bundle only AFTER committing.** Build scripts commonly stamp `git rev-parse
   HEAD` into the artifact (and append `-dirty` when the tree is unclean). Building first
   produces an artifact that contradicts the release notes and makes provenance unverifiable —
   re-do the bundle, the upload, the manifest and the emerge, or live with a lie in
   `<pkg> --version`.
3. **Trim what the target box cannot use.** npm installs optional platform packages for every
   OS/arch/accelerator; keeping only the matching libc+arch turned an 855 MB tree into 182 MB.
   Remove whole platform dirs rather than cherry-picking files, and **verify by running the
   trimmed tree**, never by inspection — a removed-but-required native addon only shows up at
   runtime.
4. `tar -cJf`, publish with `gh release upload <tag> --clobber`, and point `SRC_URI` at
   `https://github.com/<owner>/<repo>/releases/download/v${PV}/<pkg>-${PV}.tar.xz`.
5. **Pre-seed `$DISTDIR`** (`portageq envvar DISTDIR`) with the tarball before
   `pkgdev manifest`, so the manifest hashes local bytes instead of re-downloading it — and seed it
   with the artifact you *just built and verified*, not a fresh download. Manifest generation that
   re-fetches can silently record the wrong bytes: `ebuild <pkg>.ebuild digest` reported success
   while the Manifest kept the **previous** size, so the shipped Manifest disagreed with the asset
   actually published. After generating, prove the size rather than trusting the exit code —
   `grep -A1 <basename> Manifest` against `stat -c%s <distfile>` — and confirm every copy on disk
   plus the release asset hash the same before emerging.
6. `doins -r` **does preserve symlinks** (required for `node_modules/.bin`), and `fperms +x`
   both the entry script and the CLI's main `.js`. Install to the path the ecosystem expects
   (`/usr/$(get_libdir)/node_modules/<scope>/<pkg>`) so a pre-existing wrapper or systemd unit
   keeps working, and `dosym` the bin.
7. `QA_PREBUILT="*"` is the honest description of a tree of prebuilt binaries, but it does
   **not** silence scanelf's `Security problem NULL DT_RUNPATH` notice for vendored `.so`
   files (dlopen'd by path, so they carry no RUNPATH by design). Expected, exit 0 — do not
   chase it, and do not document a fix that doesn't work.

```bash
EAPI=8

DESCRIPTION="<upstream purpose> - <fork note>"
HOMEPAGE="https://github.com/<fork>/<repo>"
SRC_URI="https://github.com/<fork>/<repo>/releases/download/v${PV}/<pkg>-${PV}.tar.xz"
S="${WORKDIR}"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="mirror strip"   # strip: prebuilt native addons must not be touched
QA_PREBUILT="*"           # vendored ELF, not code we compile
RDEPEND=">=net-libs/nodejs-22"

src_unpack() { default; }
src_compile() { :; }

src_install() {
	local dest="/usr/$(get_libdir)/node_modules/@scope/pkg"
	insinto "${dest}"
	doins -r bin dist node_modules package.json LICENSE CHANGELOG.md README.md skills scripts
	fperms +x "${dest}/bin/pkg" "${dest}/dist/cli/pkg.js"
	dosym "../$(get_libdir)/node_modules/@scope/pkg/bin/pkg" /usr/bin/pkg
}
```

**Versioning a fork:** use a post-release snapshot suffix (`2.8.3_p20260929`) and name the
release tag to match. Do **not** use `-r1` — a Gentoo revision means “same source, changed
ebuild”, which is false when the source is a fork at a different commit.

**Replacing a hand-installed tree:** when the package supersedes files Portage never owned (a
root `npm install`, a wrapper in `/usr/local/bin`, hand-written units), `mv` the old tree aside
before emerging — instant and zero-copy, and a genuine rollback path — then expect
`Package merged despite file collisions`. Portage will not remove the leftovers later; they are
yours to clean up. Also check that nothing else still depends on the old install before deleting
it, and leave a hand-written safety wrapper in place if users call it by name.

## Non-standard licenses (not in the Gentoo tree)

When upstream's `LICENSE=` value is a license Gentoo doesn't ship (e.g.
`grep -i poly /var/db/repos/gentoo/licenses/` returns nothing), Portage
won't resolve it and the ebuild fails QA / can't be fetched cleanly. This
is common with **source-available / non-commercial** licenses (PolyForm,
BUSL, custom EULAs). Verified shipping `net-misc/mcp-gateway`
(PolyForm-Noncommercial-1.0.0). Four coordinated steps:

1. **Add the license text to the localrepo `licenses/` dir.** Copy the
   upstream license text file (e.g. `LICENSE-NONCOMMERCIAL`) as the exact
   `LICENSE=` value:
   ```bash
   sudo mkdir -p /var/db/repos/localrepo/licenses
   sudo cp <upstream>/LICENSE-NONCOMMERCIAL /var/db/repos/localrepo/licenses/PolyForm-Noncommercial-1.0.0
   sudo chown portage:portage /var/db/repos/localrepo/licenses/PolyForm-Noncommercial-1.0.0
   ```
   The `LICENSE="..."` in the ebuild must exactly equal this filename.

2. **Set `RESTRICT` for the non-distributable terms.** For source-available /
   non-commercial: `RESTRICT="mirror strip bindist"` —
   - `mirror` — don't mirror the source/binary on a distfile mirror
   - `strip` — keep the vendor binary unstripped (avoids breaking it)
   - `bindist` — don't redistribute a prebuilt binary package; **this is the
     flag that enforces the non-commercial distribution restriction** (a
     permissive-OSS prebuilt binary omits `bindist`)
   - `src_unpack() { mkdir -p "${S}"; }` and `src_compile() { :; }` for a
     bare-binary ebuild where the distfile is the raw ELF (no tarball).

3. **Accept the license in `/etc/portage/package.license`.** On this box
   it's a flat file (not a dir):
   ```bash
   echo "net-misc/mcp-gateway PolyForm-Noncommercial-1.0.0" | sudo tee -a /etc/portage/package.license
   ```
   The global `ACCEPT_LICENSE` in make.conf covers only common licenses; a
   source-available one not on that list needs this explicit entry or
   `emerge -pv` reports it masked by license.

4. **Verify resolution** — `sudo emerge -pv =cat/pkg-<ver>` must show
   `[ebuild N ~]` with no license mask. If still masked, the license file
   name in step 1 doesn't match the ebuild `LICENSE=` value.

Also: keep `DESCRIPTION` under 80 chars or pkgcheck flags `BadDescription`.

## Packaging a tool that a SERVICE ACCOUNT already runs (migration, not greenfield)

When the goal is to package a hand-maintained file **out of a service tree** (the
file works, but is operator-owned inside a root-owned tree and unreproducible), the
ebuild is only half the job. Three rules, learned shipping `app-misc/lta-route` and
`app-misc/stability-image` out of `/opt/mcp/bin` (2026-10-08):

1. **Package the named file, then SWEEP THE TREE for its whole class.** The request
   names the files someone noticed; the class is "anything the service account
   executes or reads that a human still owns". `find <service-tree> -user <operator>`
   is the sweep — it found a model directory (333 MB, read-only data) and an orphaned
   script that the named pair would have missed. Packaging only the named instances
   leaves the class live.
2. **Repoint the consumer in the same change, or the defect is still live.** The
   wrapper server kept exec'ing `/opt/mcp/bin/<tool>` after the package landed at
   `/usr/bin/<tool>`. New package + old `command:` path = the operator-owned file is
   still what runs. Edit the wrapper's path constant, then restart the service so the
   backend re-spawns — and re-run the manifest-parity gate (as the service account).
3. **Check what the move BROKE in the other direction.** A file moved *into* a service
   tree during an earlier migration can leave a documented path empty. Here the
   cutover had copied `x380_ps.py` into `/opt/mcp/bin` for a backend that was later
   decommissioned — orphaning the file in the service tree while the path an operator
   skill documents, `~/.hermes/x380_ps.py`, no longer existed. Nothing referenced the
   `/opt` copy; the correct fix was to restore it to the documented path, not to
   package it. A move is not done until you have checked what pointed at both ends.

Verify the result the way the service sees it: call the tool **through the gateway**
(real data, not a `--help`), run the parity gate as the service account, and confirm
`find <service-tree> -user <operator>` is empty.

### State must not be COMPOSED from the code directory — grep every writer, not just the config

When shipping a tool whose runtime state lives beside its code, moving the *config* is not the
job. In apinav, `config.py` was given a `STATE_DIR` that honoured `APINAV_STATE_DIR`, but
`embed_matrix.py` still built its paths from `APINAV_DIR` — so the embedding cache kept landing
in the code tree. It only shows up as a real failure once the package makes that directory
root-owned and read-only: every append or rebuild then fails, long after the build was green.

```bash
# after splitting STATE_DIR out of APINAV_DIR, find EVERY path composed from the code dir:
grep -rn 'APINAV_DIR\|_DIR /\|DIR / "' --include='*.py' . | grep -v __pycache__
```

A packaged code tree must be read-only to the account that runs the tool — a writable code
directory lets that account rewrite the program. Check the *directory* mode too, not only the
files: a tree left `group-writable` by an earlier migration is still writable after emerge.

### A rewritten tag means purging BOTH the distfile and the Manifest

See the stale-distfile trap above — it applies with full force when you re-cut a release tag to
pick up a fix. `pkgdev manifest` reported "manifests are up to date" while holding the OLD hash.
Delete the code tarball and the Manifest, re-manifest, then **prove the tarball carries the fix**
before trusting a green build:
```bash
tar xzf "$(portageq envvar DISTDIR)/<pkg>-${PV}.tar.gz" -O <pkg>-${PV}/<changed-file> | grep <expected>
```

A prepared bundle packed **with** a top-level directory needs `--strip-components=1` at unpack,
or pip's `--find-links` finds nothing (`No matching distribution found for <dep>`). Match the
compression to the `.tar.gz` name: the precedent uses gzip, so `tar -cJf` (xz) produces a file
`tar xzf` cannot read.

**A generated file for the bundle must be written INTO the staging dir**, not to a hardcoded
sibling path — the first licences manifest was written outside the tarball and shipped nothing.
Pass the staging dir as an argument.

## Permission model (localrepo on a multi-user box)

The localrepo tree (`/var/db/repos/localrepo/...`) is `portage:portage`
with sticky perms. The `hermes` file tools (`write_file`, `patch`,
`read_file`) run as your agent user (e.g. `carl`, uid 1001), not as
`portage`. **They will fail with `Permission denied`** if you try to
write directly into the localrepo.

**Workaround pattern:**

```bash
# 1. Write the ebuild to /tmp
#    (use write_file, works fine there)
# 2. Stage via sudo
sudo mkdir -p /var/db/repos/localrepo/<cat>/<pkg>
sudo cp /tmp/<pkg>-<ver>.ebuild /var/db/repos/localrepo/<cat>/<pkg>/
sudo cp /tmp/metadata.xml          /var/db/repos/localrepo/<cat>/<pkg>/
sudo chown -R portage:portage /var/db/repos/localrepo/<cat>/<pkg>
```

The `ebuild`, `pkgdev`, `pkgcheck` commands all need to run as the
`portage` user (so they can write into `/var/tmp/portage/...`). The
**install phase is the one exception** — it must run as root because it
calls `chown` on the image dir and only root has `CAP_CHOWN` on `/var/tmp`.

## pkgcheck pitfalls (the most common localrepo failures)

These are the warnings/errors you'll hit on a localrepo ebuild. Each one
has a known fix.

### `InvalidPackageName` — Gentoo package names cannot contain dots

Gentoo package names (PN) must match `[A-Za-z0-9+_-]+` — **no dots**. Both
`pkgdev manifest` and `pkgcheck scan` hard-fail on an upstream name with a `.`:

```
pkgcore.ebuild.errors.InvalidCPV: app-misc/whisper.cpp-1.9.2: invalid package name
```

`pkgdev manifest` silently generates nothing (exit 0, no `Manifest` file appears —
which is how this one hides). Fix: rename the directory + ebuild to the hyphenated
form (`whisper-cpp`, `llama-cpp`). Keep the upstream dot in `HOMEPAGE`/`SRC_URI` —
only the Gentoo PN is sanitized. Catch this **before** running `pkgdev manifest`;
catching it later means renaming + re-manifesting.

**Follow-on gotcha — `S` must match the tarball's top-level dir, not `${PN}-${PV}`.**
GitHub archive tarballs extract to the **upstream** repo name: `whisper.cpp-1.9.2.tar.gz`
unpacks to `whisper.cpp-1.9.2/`, but Portage defaults `S="${WORKDIR}/${PN}-${PV}"` =
`whisper-cpp-1.9.2`. The build then dies at the `prepare` phase with
`die "The source directory '${S}' doesn't exist"`. Always set it explicitly:

```bash
S="${WORKDIR}/<upstream-name>-${PV}"    # e.g. S="${WORKDIR}/whisper.cpp-${PV}"
```

Confirm the real extraction dir first: `tar tzf <distfile> | head -1`.

### `EmptyGlobalAssignment`
```
empty global assignment: RDEPEND=""
```
Fix: **don't write `RDEPEND=""`**. Just omit the line entirely. An absent
`RDEPEND` defaults to `DEPEND`'s value (and is allowed for static binaries
with no runtime deps). pkgcheck flags the explicit-empty assignment only.

### `InvalidEmail` (in metadata.xml)
```
Element 'email': The value 'carl@localhost' is not accepted by the pattern '[^@]+@[^.]+\..+'
```
Fix: schema requires a domain with a dot. `carl@localhost` is rejected.
Use `carl@gentoo.local` or any `name@host.tld` form. Don't use a real
address — this is a localrepo, not a public submission.

### `SizeViolation` / `TotalSizeViolation`
```
'files/<pkg>-<ver>-vendor.tar.xz' exceeds 20.0 KiB in size; 1.6 MiB total
files/ directory exceeds 50.0 KiB in size; 1.6 MiB total
```
Fix: don't put vendored Go deps (or any large distfile) in `files/`. Use a
proper distfile mirror instead — either:
- The system `/var/cache/distfiles/` (DISTDIR in `make.conf`)
- A `file://` mirror pointed at `<localrepo>/distfiles/`

For a precompiled-binary ebuild, this isn't an issue at all — there are
no vendored deps to ship.

### `MissingUri`
```
unfetchable file: '<pkg>-<ver>-vendor.tar.xz'
```
Same root cause as `SizeViolation` — the file is in `files/` (which is
just a relative path with no fetch URL) instead of a real distfile
location. See the fix above.

### `EbuildVariableOrder` / `VariableOrderWrong`
```
variable S should occur before KEYWORDS
```
Fix: enforce the order `DESCRIPTION → HOMEPAGE → SRC_URI → S → LICENSE →
SLOT → KEYWORDS → IUSE → RESTRICT`. Place `S` immediately after `SRC_URI`.

### `UnknownCategoryDirs` (new category not registered)

```
profiles
  UnknownCategoryDirs: unknown category dirs: sci-listen
```

Fix: the new category must be registered in **two places**:

1. **`/etc/portage/categories`** — tells Portage the category exists (required for `emerge` to accept it):
   ```bash
   echo "sci-listen" | sudo tee -a /etc/portage/categories
   ```

2. **`/var/db/repos/localrepo/profiles/categories`** — tells pkgcheck the category is valid (required for QA scan to pass):
   ```bash
   echo "sci-listen" | sudo tee -a /var/db/repos/localrepo/profiles/categories
   ```

Both are needed. Missing either one causes a different failure mode:
- Missing `/etc/portage/categories` → `emerge` fails with "no such category"
- Missing `profiles/categories` → pkgcheck reports `UnknownCategoryDirs`

**Note for standard categories** (like `app-misc`, `dev-python`, etc.): these are already in `/etc/portage/categories` by default, so only the localrepo `profiles/categories` needs the entry. Check with `grep -c "^<cat>$" /etc/portage/categories` first.

### `EmptyGlobalAssignment` on `SRC_URI=""`

```
EmptyGlobalAssignment: version 1.0.0: line 8: empty global assignment: SRC_URI=""
```

Fix: for local-script ebuilds (no upstream tarball, script lives in `files/`), **omit `SRC_URI` entirely** rather than setting it to `""`. An absent `SRC_URI` is valid for no-source packages; an explicit empty string triggers the warning.

### `MissingPythonEclass` — do NOT "fix" it by adding a python eclass

A stdlib-only Python script installed with `newbin` from `files/` needs **no
`RDEPEND` at all**: python ships in `@system`, and the script runs through
`/usr/bin/env python3`. Writing `RDEPEND="dev-lang/python"` to be explicit
triggers:

```
MissingPythonEclass: version 1.0.0: missing python-r1 or python-single-r1
eclass usage for RDEPEND="dev-lang/python"
```

pkgcheck's implied fix — add `python-single-r1` — is **wrong for this shape**: it
pulls in `PYTHON_COMPAT`/`PYTHON_DEPS` machinery for a package that never touches
site-packages. The correct fix is to **omit `RDEPEND` entirely**, matching
`app-misc/fdc` on this box. Note the scan still exits 0 with this warning, so it
ships silently if you only check the exit code — read the output.

### `PythonCompatUpdate` (harmless for localrepo)

```
PythonCompatUpdate: version 1.2.0: PYTHON_COMPAT update available: python3_15
```

Fix: add the new Python version to `PYTHON_COMPAT` if the package supports it. For localrepo ebuilds, this is a **cosmetic warning** — it doesn't block installation. Only fix if you're actively maintaining the ebuild for the new Python version.

### `NonsolvableDepsInDev` / `NonsolvableDepsInStable` (profile-specific)

```
NonsolvableDepsInDev: version 9999: nonsolvable depset(rdepend) keyword(~amd64) dev profile ... solutions: [ sys-apps/systemd ]
```

Fix: this means the dependency is only satisfiable on certain profiles (e.g., systemd vs openrc). Add a `|| ( )` any-of dependency or mark the dep as profile-conditional. For localrepo ebuilds, this is often harmless if you only use one profile.

## The 4-step test cycle

```bash
cd /var/db/repos/localrepo/<cat>/<pkg>

# Step 1: Manifest (downloads + BLAKE2B + SHA512 hashes)
sudo -u portage pkgdev manifest

# Step 2: QA (zero warnings required)
sudo -u portage pkgcheck scan

# Step 3: Full ebuild test (compile → test → install)
#   IMPORTANT: install phase needs root for chown
sudo ebuild ./<pkg>-<ver>.ebuild clean test install

# Step 4: Smoke test the installed binary
sudo /var/tmp/portage/<cat>/<pkg>-<ver>/image/usr/bin/<bin> --version
```

If step 1 fails with 404, your SRC_URI doesn't match what upstream
actually publishes. Check the latest release's assets on GitHub.

If step 2 fails, fix the warning (most are covered above), re-run
step 1, re-run step 2.

If step 3 fails on `install phase: dobin failed / cannot change
ownership`, you're not running as root. Re-run step 3 as root.

## Committing to localrepo git

```bash
cd /var/db/repos/localrepo
sudo -u portage git add <cat>/<pkg>/
sudo -u portage git -c user.name='<name>' -c user.email='<email>' \
    commit -m "<cat>/<pkg>: add <ver>

<one-paragraph description of the package, what it does, and any
non-obvious choices (e.g. 'precompiled binary because go 1.26 not
in stable', 'BDEPEND on go because source build')."
```

Commit the ebuild + metadata.xml + Manifest as a single commit. The
Manifest hashes MUST match what's in the ebuild's SRC_URI.

## Syncing localrepo to GitHub after changes (standing requirement)

The localrepo is mirrored to the public `joewis/localrepo` repo. After ANY
commit to the localrepo (new ebuild, bump, revision), push it so the mirror
stays current — this is a standing requirement, not optional.

```bash
cd /var/db/repos/localrepo
# Push as carl (holds the SSH deploy key), NOT via `sg portage` — the portage
# user can't read carl's key and the push fails with Permission denied (publickey).
git push origin master
```

**Verify against the server, not the local tracking ref.** The push can succeed and then git
still fails to update `refs/remotes/origin/master` (`cannot lock ref ... Permission denied`),
because the tree is `portage:portage` and your user may not be able to write `.git`. The
obvious-looking `git rev-list --left-right --count origin/master...master` then reports a false
`0\t1` "out of sync" from that stale ref. Confirm what GitHub actually has:
```bash
gh api repos/<owner>/localrepo/commits/master --jq '.sha + " | " + (.commit.message|split("\n")[0])'
```

- **Remote is already configured:** `origin = git@github-localrepo:joewis/localrepo.git`.
- **Push as carl, commit as portage.** The commit step above runs
  `sudo -u portage git commit`; the push MUST run as carl (the user with the
  deploy key). Do not conflate them into one `sg portage -c "git push"`.
- **Check ahead/behind first** if unsure: `git rev-list --left-right --count
  origin/master...master` — `N\t0` means N unpushed commits; push them.
- **Do this as part of every system upgrade** (the user bumps localrepo
  ebuilds during upgrades) and after any standalone ebuild work.

**A backend's injected env is ALSO sanitized — an `Environment=` on the unit does NOT reach it.**
When a service runs backends through a supervisor (the MCP gateway), variables set with
`Environment=` in the *unit* do not propagate to the backend subprocesses; only the backend's own
`env:` block does. Symptom: a state-directory variable silently fell back to its XDG default, the
tool created an empty database in `~/.local/state/`, and the tool answered
`{"error": "no such table: apis"}` while every health check was green. Put every variable a
backend needs — state dir AND credentials — in the backend's `env:` block.

**Verifying a backend under systemd: read `/proc/<pid>/environ` of the BACKEND, not the unit.**
`pgrep -f <script>` also matches your own shell when the pattern appears in your command line,
which produced a confident and completely wrong answer on the first pass. Enumerate children of
the unit's `MainPID` instead:
```bash
MAIN=$(systemctl show <unit> -p MainPID --value)
# then for each /proc/<p> whose ppid == MAIN, read cmdline and environ
```
`systemctl show <unit> -p Environment` shows what the *unit* has, which is not what a backend sees.

## Packaging a daemon a user runs (not just a CLI binary)

The patterns above cover CLI tools. A **daemon** adds three concerns — worked through on
`app-misc/camofox` (2026-10-04), a Node browser server with a systemd unit and a hand-installed tree.

1. **The unit location decides the cutover.** Portage installs units to
   `/usr/lib/systemd/system/` via `systemd_dounit`. A hand-written unit the user left in
   `/etc/systemd/system/` **SHADOWS it** — `/etc` wins over `/usr/lib` — so after `emerge` the
   service keeps exec'ing the OLD path (and fails, because you moved the old tree aside).
   `systemctl show <unit> -p FragmentPath` tells you which one is in effect; `equery belongs`
   proves the `/etc` copy is not portage's. Delete the `/etc` copy, `daemon-reload`, restart.
   **Do this before declaring the merge done** — otherwise the package looks installed and the
   service is dead.
2. **Install at the path the ecosystem already expects.** A Node daemon must sit at
   `/usr/$(get_libdir)/node_modules/<scope>/<pkg>` with its dependency siblings in
   `/usr/$(get_libdir)/node_modules/`, i.e. exactly where a global npm install put them. Then
   `dosym`/`newbin` the entry point into `/usr/bin`. Install the CLI wrapper as a real FILE
   (`newbin`), not a symlink into the tree — that is what survives a layout change.
3. **Multi-user reach decides *which* path, not just which file.** The packaged `/usr/bin` copy is
   what other users (agents running as their own uid) can actually exec; a wrapper in
   `~/.local/bin` or `/usr/local/bin` may work for the owner and be unreachable for them
   (`/home/<user>` is 700). Check with `sudo -u <otheruser> test -x <path>` before removing a
   hand-installed copy that "everyone" depends on.

**A runtime-downloaded component the package deliberately does not ship must be documented in
`pkg_postinst`, and stated as design, not apology.** camofox drives a ~1.3 GB Camoufox browser
binary fetched on first use into `~/.cache/camoufox`. Packaging it would mean a 1.2 GB distfile per
upstream bump; leaving it as a version-pinned cache is correct. Say so in `pkg_postinst`, name the
cache path, and explain why portage cannot fetch it (build sandbox has no network). Same call as
the network-assets rule — document, don't drag it through the build.

**Run the daemon from the INSTALLED IMAGE as the service user, not as root.** Running the image
binary under `sudo` looked successful but resolved the browser cache to `/root/.cache/camoufox`
(absent → it began a 1.3 GB re-download). The unit runs as `carl`, whose cache is already
populated. A root smoke test proves the tree *loads*; only a test as the unit's `User=` proves the
paths resolve. Kill stray downloads and clear the wrong user's cache afterwards.

**Building the bundle: keep the package's own tree whole.** A first pass trimmed `*.md`, `test/`,
`docs/` and broke the install (`dodoc` on a now-missing upstream README). The daemon also loads
files from its package dir by relative path, so a deletion only surfaces at install or runtime.
Trim ONLY (a) other platforms' native prebuilds (better-sqlite3 ships one `.node` per OS/arch —
keep `linux-x64.node`) and (b) whole optional packages upstream resolved for other OS/arch.
Verify the trimmed tree by RUNNING it (require the package, open the sqlite binding, start the
server), never by listing files.

**A release asset replaced under the same tag can be served stale from the CDN.** After
`gh release upload --clobber`, `pkgdev manifest` re-fetched the PREVIOUS bytes (old size in the
Manifest) even though `gh release view` reported the new size. Pre-seed `$DISTDIR` with the
artifact you built and verified, then manifest; and confirm the Manifest size equals
`stat -c%s` of that artifact. A fresh `curl` of the release URL eventually matched — the CDN just
lags. Never let manifest generation be the thing that decides which bytes ship.

## Rebuilding a prepared-bundle package (the recipe lives in the VAULT)

A prepared-bundle ebuild (Node/TypeScript, no npm eclass) is **not reproducible from the ebuild
alone** — the bundle is assembled outside portage, so the build scripts are load-bearing and must
not live in a scratch dir that gets cleaned. For each such package, the full rebuild/bump recipe
is kept in the shared vault:

- **`/home/carl/sysadmin-vault/Notes/camofox ebuild rebuild.md`** — worked example and template:
  bump procedure end to end, the traps that cost real time, and the verification sequence.
  Its build scripts sit beside it at `Notes/camofox-ebuild/{stage.sh,assemble.sh}`.
- **`/home/carl/sysadmin-vault/Notes/xiaomi-devices ebuild rebuild.md`** — prepared-bundle
  ebuild for a *Python* package (app-misc/xiaomi-devices): a 54-wheel / 23 MB dependency
  bundle published as a release asset, venv under `/opt`, wrappers in `/usr/bin`. Its
  build script is `Notes/xiaomi-devices-ebuild/assemble.sh` (resolves the tree, writes a
  `licenses.txt` because the bundle redistributes other people's wheels).

**A download can truncate and look like a bad asset.** `curl -L` on a GitHub release asset
returned exactly 10 MiB (10485760 bytes) of a 23 MB tarball, failing `gzip -t`, while
`gh release download` fetched the correct bytes with the expected sha256. Before concluding an
asset is stale or corrupt, re-fetch with `gh release download --pattern ... --clobber` and hash
that — and treat an exact 10 MiB size as a transfer limit, not a manifest problem.

Search the vault for a rebuild note before reconstructing one from memory:
```bash
qmd search "<pkg> ebuild rebuild" || grep -ril "<pkg>" /home/carl/sysadmin-vault/Notes/
```

**When you ship a new prepared-bundle package, write its rebuild note to the vault in the same
session** and link it from this section. A recipe parked in `~/.hermes/` or `/tmp` is the thing
that gets forgotten — which is the whole failure mode this packaging is meant to fix.

## The precompiled-binary pattern (full template)

For Go CLI tools (goreleaser output), this is the simplest working
template — ~25 lines, zero RDEPEND, zero build deps. Verified shipped
to localrepo on Gentoo, July 2026.

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
    mv reponame reponame-bin 2>/dev/null || die "reponame binary not found in archive"
}

src_install() {
    newbin reponame-bin reponame
    dodoc LICENSE README.md CHANGELOG.md
}

pkg_postinst() {
    elog "<first-run hint>"
}
```

The full rationale for each line (why `RESTRICT="... strip"`, why the
`mv` rename, why explicit `dodoc` not `einstalldocs`, etc.) is in
`references/localrepo-precompiled-binary-ebuild.md`.

**Variant: bare-ELF precompiled binary (no tarball).** When upstream ships a
single self-contained ELF as a raw release asset — no tarball, no wrapper,
nothing to extract (agent-browser from Vercel Labs is the worked example) —
the pattern is in `openclaw-imports/write-ebuild` under
"Precompiled binary package (no source compile) → Bare-ELF precompiled binary".
The localrepo-specific pitfalls for that shape:

- **`src_unpack` copies, it does not `default`.** A bare ELF has no tarball, so
  the default unpack (which expects `A` to be an archive) fails. Use
  `mkdir -p "${S}"` + `cp` + `chmod`.
- **The stale-distfile trap bites harder here.** A versionless `SRC_URI`
  basename (e.g. `agent-browser-linux-x64` with no `${PV}`) keeps hashing the
  same cached bytes across versions — the new ebuild "builds" but installs the
  old binary, and unlike a tarball case there is no extraction directory to
  catch the mismatch. Always version-stamp the basename.
- **Runtime deps are documented, not declared.** If `ldd` shows only glibc
  family libs, there is no `RDEPEND` beyond `@system`. A non-library runtime
  requirement (Chrome, for agent-browser) goes in `pkg_postinst` — it cannot
  be a hard dep because the CLI either reuses an installed browser or fetches
  one on demand.

## Publishing the localrepo to a public GitHub repo

When the user wants the localrepo (or any portage-owned overlay) pushed to GitHub, the operational layer differs from a normal repo push:

1. **Inspect first** — the localrepo is a git repo owned by `portage` on `master` with no remote, and often has a batch of *untracked* packages on disk that were never committed. `git status --short` reveals them. Add `git config --global --add safe.directory /var/db/repos/localrepo` to clear the dubious-ownership guard before inspecting.

2. **Gitignore generated/local-only content** — never commit these to a public overlay:
   - `distfiles/` — large binary distfiles (a local mirror), not source
   - `metadata/md5-cache/` — regenerated automatically by pkgdev
   - `*.ebuild.new` — leftover work-in-progress ebuilds (a `.new` file is a Go `EGO_SUM` variant that was never finalized; the live `.ebuild` is the git-version one)
   ```bash
   printf 'distfiles/\nmetadata/md5-cache/\n*.ebuild.new\n' | sudo tee /var/db/repos/localrepo/.gitignore
   ```

3. **Secret-scan before pushing public** — grep all untracked ebuilds/configs/files for `api[_-]?key|secret|password|token|BEGIN (RSA|OPENSSH|PRIVATE)|ghp_|github_pat_|sk-`. Use `sudo` (some files are portage-owned). Note benign false positives: searxng's stock `secret_key: "ultrasecretkey"` placeholder and `elog` hints are fine — only real credentials block the push.

4. **Commit as portage, push as a user with SSH** — the tree is `portage:portage`. Stage/commit via `sudo -u portage git ...` (with `-c user.name/-c user.email`). To push, add your user to the `portage` group and make `.git` group-writable. **Split the two git operations by who runs them:**
   - **Config write** (remote add/set-url) needs the portage group, which the current shell doesn't have until re-login — run it via `sg portage`:
     ```bash
     sudo usermod -aG portage <user>
     sudo chmod -R g+w /var/db/repos/localrepo/.git
     cd /var/db/repos/localrepo && sg portage -c "git remote add origin git@github-<alias>:<owner>/localrepo.git"
     ```
   - **Push** must run as the **user** (carl), NOT via `sg portage`. `sg portage -c "git push"` fails with `Permission denied (publickey)` because the `portage` user can't read carl's SSH deploy key. Push as carl directly:
     ```bash
     cd /var/db/repos/localrepo && git push -u origin master
     ```
   Do not conflate the two into one `sg portage -c "git push"` — the config write needs the group, the push needs the user's key.

5. **Create the repo + deploy key** — `gh repo create localrepo --public --source . --remote origin` (the `--remote` may fail; add it manually). A deploy key scoped to another repo won't push here — generate a fresh one for the new repo (see the github-workflows skill's per-repo deploy-key pattern) and give it its own SSH config alias. **Store the deploy key in `~/.ssh/`, NOT `/tmp`** — a `/tmp` key is lost on reboot and a temp-file cleanup deletes the private key while it's still registered on GitHub, breaking future pushes until you regenerate and re-add it.

## Resources

- **Non-standard licenses** — see the "Non-standard licenses (not in the
  Gentoo tree)" section above: how to add a license file to the localrepo,
  set `RESTRICT="mirror strip bindist"`, and accept it via `package.license`
  (verified with mcp-gateway's PolyForm-Noncommercial-1.0.0).
- **`references/appimage-binary-ebuild.md`** — AppImage extraction pattern:
  `--appimage-extract` in `src_compile`, `inherit desktop` for GUI
  integration, `fperms` after `doins -r`, and the `S="${WORKDIR}"`
  trap (Obsidian 1.13.7, verified 2026-09-12).
- **`references/localrepo-precompiled-binary-ebuild.md`** — full rationale for
  the precompiled-binary pattern, the 7 most common pitfalls with their
  exact error messages and fixes, the acceptance checklist for a shipped
  ebuild, and the full runpodctl worked example (source build attempted
  first, pivoted to binary mid-debug, shipped in ~15 min).
- **`references/pure-python-ebuild.md`** — pattern for pure-Python packages
  whose heavy runtime deps (torch, numpy) are installed via pip, not Portage.
  Covers `python_domodule`, `pkg_postinst` hints, and the no-DEPEND decision.
- **`references/local-script-ebuild-fdc.md`** — worked example of the
  local-script ebuild pattern (no upstream tarball, script in `files/`):
  app-misc/fdc, a Python CLI wrapper for the USDA Food Data Central API.
  Covers the full ebuild, directory structure, variable ordering without
  `SRC_URI`, install sequence, the `nutrients`/`codes` commands added in
  1.1.x, the `search --nutrients` one-shot (1.1.3), the `--json` flag for
  script/agent use (1.1.4), the `docs` command for machine-readable CLI
  introspection (1.1.5), and the durable API fact that FDC has **no**
  standalone nutrient-code endpoint (codes only come back embedded in food
  queries).
- **`scripts/backend_dep_audit.py`** — run BEFORE choosing an ebuild shape: walks a set of
  Python tools, extracts their real third-party imports (AST, stdlib subtracted), and marks
  each one in-tree / not-in-tree. Prevents the over-scoped wheel bundle when the direct dep
  set is small and already packaged.
- **`references/service-account-ebuild.md`** — creating a service user/group as Portage
  packages (`acct-user` + `acct-group`): ID allocation, both ebuild skeletons, why pkgcheck's
  `PotentialStable` and an empty Manifest are correct here, and the checklist of what a
  service account does NOT fix by itself (the unit cutover is a separate project). Follow the
  existing `searxng` pair in this overlay rather than inventing a shape.
- **`references/pip-wheel-data-sandbox-fix.md`** — the pip-wheel `.data/data`
  sandbox violation (piper-tts 1.8.0): why `addpredict` and wheel-stripping
  fail, and the working manual-unzip `src_install` pattern.
- Parent skill: `openclaw-imports/write-ebuild` — covers ebuild syntax,
  phase functions, eclass reference. This skill complements it with the
  localrepo operational layer.
