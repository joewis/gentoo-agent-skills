---
name: gentoo-system-update
description: "Full Gentoo system update routine — sync repos, emerge world, update flatpak, update global npm packages, clean up. Also covers a quick 'how stale is this box' probe."
---

# Gentoo System Update

Complete system update routine for this Gentoo machine.

## Quick probe: "How stale is this box?"

When the user asks "when was the last update?" or "is this box up to date?" — do this read-only check first, then decide whether to run the full update below. Don't sync just to count — `emaint -a sync` modifies state and on slow links takes minutes.

```bash
# 1. Last few emerge operations (epoch-seconds prefix, decode with `date -d @<n>`)
sudo tail -200 /var/log/emerge.log | grep -E '^[0-9]+: Started emerge' | tail -5
# 2. Last full sync — repo dir mtime
sudo stat -c '%y' /var/db/repos/gentoo 2>&1 | head -1
# 3. Running kernel vs available source trees
uname -r
ls -d /usr/src/linux-*-gentoo* 2>/dev/null
# 4. Unread news items (the `N` markers)
sudo eselect news list | head -20
# 5. Count of outdated packages (does NOT sync — just reports against the on-disk tree)
sudo emerge -pv @world 2>&1 | grep -c '^\[ebuild'
```

Report back in a small table: `last emerge`, `last sync`, `running kernel`, `kernel sources available`, `unread news`, `outdated pkgs`. User decides if/when to run the full update.

## Steps

### 1. Sync repos

```bash
sudo emaint -a sync
```

### 2. Update the package manager itself first

```bash
sudo emerge --oneshot --verbose sys-apps/portage
```

**Expected noise during portage self-update:** The output may list masked packages (e.g., `app-arch/p7zip`, `net-dns/bind-tools`). These are informational warnings, not blockers. Portage itself upgrades cleanly. Note the replacements (`7zip` for `p7zip`, `bind` for `bind-tools`) and migrate those packages separately if needed.

### 3. Full system update

```bash
sudo emerge --verbose --update --deep --changed-use @world
```

Non-interactive (no `--ask`): works in automated contexts like cron/agent runs.
Interactive: add `--ask` when running in a real terminal.

### 3b. The autounmask loop

`emerge -vu --deep --changed-use @world` exits 1 with a USE/mask change request
rather than a build error — this is the normal failure mode of a large update,
not a broken package. Portage prints a single USE requirement, then aborts.

**Diagnose the request before acting on it.** Read the tail of the log:

```bash
tail -20 /tmp/world-update.log | sed 's/^/  /'
```

The request is one of:

| What it says | Meaning | Action |
|---|---|---|
| `The following USE changes are necessary to proceed:` + `>=<pkg>-<ver> <flag>` | One package needs a USE flag to satisfy a dependency. | Add to `/etc/portage/package.use/<pkg>` (one line, `>=cat/pkg-<ver> <flag>`). |
| `The following keyword changes are necessary to proceed:` + `~<cat>/<pkg>` | A package is `~amd64` but not pinned. | Add `cat/pkg ~amd64` to `/etc/portage/package.accept_keywords/<pkg>` (bare form, see below). |
| `The following masks are necessary to proceed:` | A package is masked upstream (e.g. `net-misc/ntp` slated for removal). | Add to `/etc/portage/package.unmask/<pkg>`. Reversible — no service change. |

**Then re-run `emerge -pvu --deep --changed-use @world`** — do NOT jump straight to
`emerge -vu`. The pretend resolves the dependency graph and reports the *next*
request, and there can be several in sequence (this session: USE first, then
re-run found nothing more). Re-running pretend after each change is the loop;
emerging after the first change just fails again with the second.

**Long binary-mismatch lists are noise.** Portage prints every binhost package
whose USE doesn't match the local profile (e.g. `=media-video/pipewire-1.6.9 X
gstreamer selinux sound-server -systemd`). These are informational — those
packages build from source instead of taking the binary. Ignore the list; act
only on the single USE/keyword/mask line at the bottom.

**Never blanket-accept.** Review each change: a USE flag pulled in by
`aircrack-ng[airdrop-ng]` is a real requirement; a keyword change exposing a
`~amd64` package is a judgement call. If unsure, add it and re-run pretend —
the resolution tells you whether it was needed.

### 4. Preview depclean (critical safety step)

```bash
# Always preview what depclean will remove before running it
sudo emerge --depclean --pretend
```

**Depclean refuses to run — two failure modes, both about stale recorded deps, not a broken tree:**

1. `dev-cpp/eigen:3/3= pulled in by dev-python/pybind11` while eigen *is* installed.
   The consumer recorded the library's old **subslot** at build time (`eigen:=` pins
   the subslot in use then). Rebuilding the library does nothing — eigen was already
   current at `3/3.4`. Rebuild the **consumer** (`emerge -1 dev-python/pybind11`) so it
   re-records `eigen:3/3.4=`. Cheap test for this: compare
   `cat /var/db/pkg/<cat>/<lib>-<ver>/SLOT` against the atom in the consumer's
   `/var/db/pkg/<consumer>/RDEPEND`.
2. The same message names a package that was removed, not one with a stale subslot —
   then it really is missing; emerge it.

**Depclean can select the ACTIVE toolchain for removal.** `selected: 15.3.0` under
`sys-devel/gcc` is not a spare slot when `gcc-config -c` reports `x86_64-pc-linux-gnu-15`.
Portage has no idea which slot `gcc-config`/`binutils-config` point at; it just keeps the
newest stable and drops the rest. Before running depclean, cross-check every `sys-devel/gcc`
and `sys-devel/binutils` entry in the selected list against `gcc-config -c` and
`binutils-config -c`. If they match the selected version, switch first
(`gcc-config x86_64-pc-linux-gnu-<new>`, `binutils-config x86_64-pc-linux-gnu-<new>`,
`env-update && . /etc/profile`), verify `gcc --version`, then depclean. Confirm the new
compiler actually builds and links (`printf 'int main(){return 0;}' | gcc -x c - -o /tmp/t && /tmp/t`)
before declaring the update done.

**Key things to check in the preview:**
- **Running kernel sources** — depclean can remove the running kernel's `gentoo-sources` even when it's in @world, if a newer version in a different slot was also installed by the @world update. The preview shows `selected:` (will be removed) vs `omitted:` (kept). If the running kernel's version is `selected`, the source dir persists (with your `.config`) but the package is gone — you'll need to re-emerge it if you want to build that kernel again.
- **dracut/genkernel** — if dracut is listed for removal, note it. You may need it for initramfs generation later.
- **xorg-server slot bumps** — if depclean complains about old slots still needed, rebuild the consumers first (see troubleshooting below).
- **distcc masquerade follows the toolchain.** If this box runs `distccd` (serves another machine's compiles — see [[Services and Ports]]), the symlinks in `/usr/lib/distcc/bin` point at whatever `gcc-config`/`binutils-config` selected. After switching the active toolchain, confirm the masquerade still resolves (`ls -l /usr/lib/distcc/bin/gcc`) and that the **client machine's compiler version matches** — distcc compiles with the server's toolchain and does not verify the client's, so a mismatch yields objects the client's linker was not built for. A real compile through the daemon (`DISTCC_HOSTS=localhost/2 distcc gcc probe.c`) is the proof, not a `--version` check.

### 5. Run depclean

```bash
sudo emerge --depclean
```

**Troubleshooting:** If `emerge --depclean` gives dependency errors about old slots (e.g. xorg-server:0/21.1.22= still needed by xf86-video-intel), rebuild the affected package first with `sudo emerge --oneshot --verbose x11-drivers/xf86-video-intel`, then retry depclean.

```bash
# Rebuild xorg drivers against new xorg-server slot
sudo emerge --oneshot --verbose x11-drivers/xf86-video-intel x11-drivers/xf86-input-libinput x11-drivers/xf86-video-vesa x11-drivers/xf86-video-dummy
# Then retry depclean
sudo emerge --depclean
```

### 6. Clean packages and distfiles

```bash
# On systems using a binhost at /var/cache/binhost/gentoo, eclean may
# fail with FileNotFoundError on /var/cache/binpkgs/Packages.
# Either run separately or set up the PKGDIR symlink:
sudo eclean packages 2>&1 || sudo mkdir -p /var/cache/binpkgs && sudo eclean packages
sudo eclean distfiles
```

### 5. Update flatpak apps (if installed)

```bash
flatpak update 2>/dev/null || true
```

### 6. Update global npm packages

Updates all globally installed npm packages:

```bash
# Check first
npm ls -g --depth=0
# Update — may need sudo if npm prefix is /usr/lib64
sudo npm update -g
npm ls -g --depth=0
```

Note: `sudo npm update -g` works, but `npm ls -g` may show `/usr/lib (empty)` afterward when packages actually live in `/usr/lib64/`. The display quirk doesn't affect functionality — verify with `ls -la /usr/lib64/node_modules/`.

### 7. Update kernel symlink (after depclean removes old sources)

```bash
# Check if the symlink went stale
ls -la /usr/src/linux
eselect kernel list
# Set to the available target if needed
sudo eselect kernel set 1
```

**If you plan to build a new kernel after depclean:** depclean may have removed the only source tree. You will need to re-emerge `gentoo-sources` (possibly a newer version). Newer kernel ebuilds are often keyworded (`~amd64`) — if `emerge` reports masking, update `package.accept_keywords` or use `ACCEPT_KEYWORDS="~amd64"` for the one-shot emerge.

## Localrepo freshness check + ebuild bump (part of every system upgrade)

The localrepo (`/var/db/repos/localrepo`) holds hand-written ebuilds. **`eix`/`emerge -pv` cannot detect staleness here** — the localrepo ebuilds *are* the definition of "available", so the check is circular and can never fail. To find stale localrepo packages you MUST compare installed versions against **actual upstream releases** (GitHub tags, PyPI, crates.io, npm), not against the localrepo's own ebuild list.

### The check (upstream, not local)

```bash
# 1. List versioned (non-9999) localrepo packages
find /var/db/repos/localrepo -name "*.ebuild" ! -name "*9999*" | sed 's|/var/db/repos/localrepo/||; s|/.*||' | sort -u

# 2. For each, read HOMEPAGE/SRC_URI to find the upstream source
#    (sudo cat — ebuilds are portage:portage 600)
sudo cat /var/db/repos/localrepo/<cat>/<pkg>/<pkg>-<ver>.ebuild | grep -E "HOMEPAGE|SRC_URI"

# 3. Compare installed vs upstream latest
#    GitHub:  curl -s https://api.github.com/repos/<org>/<repo>/releases/latest
#    PyPI:    curl -s https://pypi.org/pypi/<pkg>/json
#    Compare against `eix <pkg>` "Installed versions"
```

**Caveats:**
- **fdc is a false positive** — it's a local custom script (`files/fdc.py`), no upstream to track. The PyPI `fdc` package is a *different* project. Skip it.
- **whisper-cpp / llama-cpp** use build tags (`bNNNN`) in addition to semver tags. The ebuild's `SRC_URI` scheme tells you which to compare against (`v${PV}` → semver; `b${PV}` → build tag). **CRITICAL: the `bNNNN` tags are nightly PRERELEASES** (`prerelease: true` in the GitHub API). The stable release is the semver tag (`v0.4.0`), which is what GitHub marks as "Latest". Always check `releases/latest` (the stable one) and the `prerelease` flag — do NOT bump to a `bNNNN` tag thinking it's the latest release. Prefer the stable semver scheme (`v${PV}`) for the ebuild.
- **moomoo-opend** isn't on GitHub — check its download page manually.
- Some staleness may be intentional (pinned for stability) — confirm with the user before bumping.

**Version-scheme drift is a *trap*, not just a nuisance — Portage's version sort lies across schemes.**

When upstream changes its versioning scheme (e.g. llama.cpp dropped `bNNNN` build tags and moved to `v0.9.0` semver), the naive move is to bump the ebuild's `PV` to the newest upstream tag. That is wrong twice over:

1. **Portage sorts `9784` below `0.9.0`** — numeric comparison, so a June build-tag commit reads as a *downgrade* of a November semver release. `emerge -pv` reports `[downgrade]` and the operator's instinct is to revert, when the correct move is to bump.
2. **The old tag may be gone.** Upstream can stop publishing a scheme entirely — `b9784` was no longer fetchable, so the old pin couldn't be rebuilt at all. The package was unmergeable, not merely stale.

Before bumping, confirm the scheme actually still exists at the target tag: fetch the tag ref (`git/refs/tags/<tag>` or the GitHub API), check the commit date, and verify the tarball URL resolves. If the old scheme is dead, the ebuild must switch schemes — and the `SRC_URI` pattern changes with it (`b${PV}` → `v${PV}`), which is a new distfile and a new Manifest regardless of what the version number looks like.

### Bumping a stale ebuild (per package)

Follow the `localrepo-ebuild-shipping` skill's pipeline: write to `/tmp`, stage via `sudo cp` + `chown portage:portage`, `pkgdev manifest`, `pkgcheck scan` (exit 0), `ebuild clean test install`, smoke test, commit as portage. Key gotchas:
- **Sibling packages that both bundle the same CMake config** — whisper-cpp 1.9.5 and
  llama-cpp 0.9.0 both install `/usr/lib64/cmake/ggml/ggml-config*.cmake`, which is a hard
  file collision at merge time (`Package NOT merged due to file collisions`), not a build
  failure. Decide who owns it: llama-cpp is the ggml provider, so whisper's `src_install`
  gets `rm -rf "${ED}/usr/$(get_libdir)/cmake/ggml" || die`, then re-emerge whisper before
  retrying llama-cpp. When a build dies at the *merge* phase after a full compile, the
  existing WORKDIR is reused on retry, so the second emerge is incremental.
- **Version-locked accept_keywords pins** — update `=cat/pkg-<oldver>` → `=cat/pkg-<newver>` in the per-package file under `/etc/portage/package.accept_keywords/` (NOT `zz-localrepo`; pins live in individual files like `sag`, `gogcli`, `llama-cpp`). Some packages use a bare `cat/pkg **` (unmasked) — no pin update needed.
- **Stale distfile cache** — if the SRC_URI basename has no version (e.g. `runpodctl-linux-amd64.tar.gz`), the old Manifest hash points at the cached old binary. Remove the stale distfile + Manifest, regenerate.
- **pip-wheel sandbox trips** — wheels that ship `.data/data/*` files or console-script wrappers make pip write to real system paths (`/usr/COPYING`, `/usr/bin/<script>`) ignoring `--root`, tripping the sandbox. Fix: bypass pip with a `files/install-wheel.py` helper that unzips the wheel into site-packages and generates wrappers from `entry_points.txt`. See the piper-tts / onnxruntime ebuilds for the working pattern.
- **pkgcheck `WhitespaceFound`** — indented lines inside an inline heredoc trigger it. Move the logic to a `files/` helper script instead of an inline heredoc.

## Automated / Cron Mode

When the user wants this on a schedule (weekly Friday 23:00 was the actual install), the recipe above still applies but the **execution model changes**:

- **Use LLM-driven cron (`no_agent=false`), NOT the watchdog pattern.** A pure bash script can't resolve slot conflicts, masked packages, or news items. The agent must reason at multiple points (depclean block, npm dual-install, eclean binpkgs dir, kernel symlink drift). A bash watchdog will either fail silently or spam raw errors. Token cost is ~5-15K/week for a normal update.
- **Two-phase script pattern** — split the recipe into a preflight (sync + portage self + `emerge -pv @world` + news count) that writes a structured state file, then have the agent do the long step (`@world` emerge, depclean, eclean, npm, flatpak, kernel symlink) and emit the summary. The preflight has bounded runtime; the long step is where the agent earns its keep. Both phases must write to a state file the agent can read (`/home/carl/.hermes/work/gentoo-update/state.json` was the actual install).
- **Telegram delivery** comes from the agent's final message, not from the script. Script stdout goes to log; agent's final response goes to origin. The agent's prompt should demand a terse summary — table or one-liner — not a wall of text. On a clean week, "Updated N, K removed, no news, no issues" is enough.
- **Failure handling**: agent reports and stops, does not loop. Jowi (the principal) decides whether to keep going. Don't try to auto-fix `emerge` failures beyond the documented pitfalls (xorg-server slot rebuild, binpkgs dir, npm symlink).
- **Cron schedule syntax** in Hermes accepts standard cron (`0 23 * * 5`) but **not** English day names (`FRI` is rejected). Use numeric weekday 0-7 (Sun=0 or 7, Fri=5).
- **See `hermes-cron-design` for the watchdog vs LLM-driven decision, the no_agent=true/false trade-off, and the script-level redirect discipline.**
- **Preflight script template:** [`scripts/gentoo-update-preflight.sh`](scripts/gentoo-update-preflight.sh) — bounded bash (sync + portage self + pretend + news) writing `state.json` for the agent. Copy, edit paths/schedule, drop in `~/.hermes/scripts/`.

## Pitfalls

- `emerge --sync` requires the portage user to have write access — use `sudo`
- `emerge --ask` only works in an interactive terminal — omit in automated/non-interactive contexts
- `emerge --depclean` can remove packages pulled in by now-removed deps — review the list before confirming
- **Kernel sources removed by depclean:** Before running `emerge --depclean`, verify that `sys-kernel/gentoo-sources` is in @world or protected. If your running kernel's sources are the only installed version and depclean removes them, `/usr/src/linux` will dangle. Check with `eselect kernel list` and `qlist -I sys-kernel/gentoo-sources` beforehand. See [references/kernel-sources-preservation.md](references/kernel-sources-preservation.md).
- xorg-server slot bumps can block depclean — rebuild consumers first
- `eclean` is from `app-portage/gentoolkit` — install if missing
- `eclean packages` may fail with `FileNotFoundError: /var/cache/binpkgs/Packages` if PKGDIR points to a binhost location; create the `/var/cache/binpkgs/` directory as a workaround
- `npm update -g` via `sudo` works, but `npm ls -g` display may show `/usr/lib (empty)` after — check `/usr/lib64/node_modules/` instead
- `wpctl` (WirePlumber) volume controls are at `40`, not `alsa` — don't confuse with `amixer`
- After depclean removes old kernel sources, update the `/usr/src/linux` symlink
- **The right log is `/var/log/emerge.log`, not `/var/log/portage/`**. The latter is for the `elog` viewer and may not have been touched in months even after a fresh `emerge`. `genlop` is not installed by default — decode epoch prefixes directly: `tail -200 /var/log/emerge.log | grep '^Started emerge'` then `date -d @<n>` on the numeric prefix.
- **`eselect news list` output shows unread items with an `N` marker**. Users can ignore for years, but security-relevant ones block `emerge` with `* IMPORTANT: N news items need reading` warnings. Check before declaring the system up to date.
- **Keyworded kernel sources not in @world are depclean candidates.** If `gentoo-sources` was installed via `ACCEPT_KEYWORDS="~amd64"` or a one-shot emerge and is not in the world set, `emerge --depclean` will remove it — even if it's the *newer* version. After depclean, only the stable (world-set) sources remain. Check `eselect kernel list` and re-emerge the desired version explicitly if needed.
- **Outdated-pkg count is meaningless without a fresh sync.** `emerge -pv @world` against a 30-day-old tree will undercount. If the count seems suspiciously low, also check the sync timestamp from step 2 of the probe.
- **Re-emerging a package re-writes its config files as `._cfg0000_<file>`** — Portage never overwrites a file the operator has edited, it stages a merge candidate alongside it. **Diff every `._cfg0000_*` file before discarding it.** The default the package ships is not the value you want: this session the stock `/etc/hosts` dropped the `x380` entry and the stock `searxng/settings.yml` dropped 287 lines of engine config plus a real `secret_key` and `base_url`. Both were kept. The rule is not "take upstream" or "keep yours" — it is **keep the operator's file unless the stock change is actually wanted**, and that call is made per file from the diff, not from a blanket `etc-update`/`dispatch-conf` run. `sudo find /etc -name '._cfg????_*'` lists what's pending; nothing is pending until you look.
- **A config replacement under `/etc` can revoke privileged access — including the agent's own.** `sudoers` is a protected file, so a `sudo` upgrade stages `._cfg0000_sudoers` like any other. Seen in practice: the staged candidate looked purely additive, because the first ~30 lines of the diff were new upstream comments — the *removed* lines further down were the `NOPASSWD` grants for the agent account **and** the desktop user. Replacing the file removed the agent's root access and the human's passwordless sudo, and recovery required the human's password typed into a real terminal. Rules:
  - print the **entire** diff — never window it with a line limit; the lines that matter are exactly the ones a window drops
  - before writing, grep the **current** file for the identities and grants that can be lost: `sudo grep -nE 'hermes|carl|joerg|NOPASSWD|%wheel|env_keep' /etc/sudoers`
  - `sudo visudo -cf <candidate>` proves **syntax only**, never that privileges survive — "parsed OK" is not approval to apply
  - keep privileged grants in `/etc/sudoers.d/*` (mode `0440`) so an upstream `/etc/sudoers` replacement cannot erase them
  - never chain `apply && verify`: the verification then only runs *after* the damage is written
  - confirm an independent path to root exists (the human's own wheel+password) before replacing anything that governs access
  - same class, same care: `sshd_config`, `pam.d/*`, `/etc/init.d/*`, `fstab`, `shadow`/`gshadow`
- **Stale npm trees are often orphans, not just dual installs. The dual-install shape is newer-in-the-wrong-place; a commoner one is a tree nothing references. npm's Gentoo global root is /usr/lib64/node_modules, so every sudo npm install -g writes there — a /usr/lib/node_modules/<pkg> copy that no symlink, no unit file, and no process points at is just disk waste (524 MB in one case). Before deleting, confirm all four checks resolve to the SAME tree: readlink -f $(which <pkg>), sudo npm root -g, the service's ExecStart, and lsof +D <path> (open handles mean NOT stale). Never blanket-remove /usr/lib/node_modules/*/ — that nukes every package there, not just the stale one; move the tree aside by name, verify nothing broke, then delete. NPM `update -g` can create a dual install on multi-lib systems.** On Gentoo amd64, `npm prefix -g` is `/usr` (writes to `/usr/lib/node_modules/`) but the active symlinks may point to `/usr/lib64/node_modules/`. After `sudo npm update -g`, always verify the *running* version (`<pkg> --version`) against the *symlink target* (`readlink -f $(which <pkg>)`). If they differ, the old copy is still active — remove or relink manually. See [references/npm-dual-install-cleanup.md](references/npm-dual-install-cleanup.md) for the full cleanup procedure.
- **Depclean can remove the running kernel's gentoo-sources even when it's in @world.** This happened in practice: `gentoo-sources-7.1.4` was in @world and was the running kernel, but depclean removed it because a newer version (`6.18.41`) was also installed by the @world update and occupied a different slot. The source directory persists (with `.config`), but the package is gone. After depclean, always run `eselect kernel list` — the symlink may still point to the removed version. Fix with `sudo eselect kernel set <N>` to the remaining target.
- **Don't assume newer sources are stable.** A kernel ebuild being installed (e.g. `gentoo-sources-7.1.3`) does not mean it's stable. Always check `equery y <pkg>` or grep `KEYWORDS` in the ebuild before telling the user to build it. Keyworded (`~amd64`) sources should not be presented as automatic upgrades unless the user explicitly tracks ~arch.
- **Keyworded dependency chains on targeted upgrades.** When upgrading a single package that pulls in keyworded (`~amd64`) deps, `emerge` fails with "all ebuilds have been masked." The fix: `sudo ACCEPT_KEYWORDS="~amd64" emerge --oneshot --verbose <pkg>`. Don't add global `~amd64` in `package.accept_keywords` — scope it to the single emerge command or a narrow accept_keywords entry. Verify with `--pretend` first.
