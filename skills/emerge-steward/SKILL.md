---
name: emerge-steward
description: Install packages on the Gentoo host using emerge. Triggers when the user asks to install, emerge, or add software to the system. Also triggers for updating, upgrading, or syncing the package manager. All installations are logged to the workspace package_history.log for auditability.
---

# Emerge Steward

Safely install, update, and audit packages on the Gentoo host using the Portage package manager.

## User Preferences

- **Sync method**: User prefers `emerge-webrsync` (fetches compressed snapshot) over live `emerge --sync` (rsync). Run `sudo emerge-webrsync` first unless they say otherwise.
- **Binary packages**: User enabled the Gentoo binhost (x86-64-v3 — their i7-10700T supports it). See [Binary Package Setup](#binary-package-setup) below.
- **Profile**: `default/linux/amd64/23.0/systemd`. `PYTHON_TARGETS` and `PYTHON_SINGLE_TARGET` default to `python3_14` from the profile.
- **Removal approach**: When a package has USE flag conflicts the user doesn't want to resolve, removing it via `--deselect` + `depclean` is preferred over wrestling with USE overrides — but always ask first.
- **Everything through Portage — NO pip/self-update bypasses.** The user is emphatic: a sysadmin updates packages on Gentoo via `emerge`, never via `pip install --break-system-packages`, never via a tool's own self-updater (`yt-dlp -U`, `npm -g`, etc.). Those write files Portage doesn't track, so `emerge` loses track of them and the system drifts. If a package isn't in the tree, check the ebuild's **real** dependencies first — they're often optional, not required (e.g. `curl_cffi` looked needed for TikTok but yt-dlp's native JS solver handled it fine). Only if a dep is genuinely required and absent from the tree do you write a localrepo ebuild (see `localrepo-ebuild-shipping`). After any manual install, audit for untracked leftovers: `pip list`, `ls ~/.local/lib/python*/site-packages/`, `ls /usr/local/bin/` — and remove them, replacing with the Portage version. (Recorded 2026-08-18: I used `pip --break-system-packages curl_cffi` and `yt-dlp -U`; user corrected me; cleaned up by emerging `net-misc/yt-dlp` + `app-misc/jq` and removing the manual binaries and user-site pip leftovers.)

## Workflow — Install a Single Package

1. **Check if package exists**: `esearch <package>` (or `ls /var/db/repos/gentoo/<cat>/<pkg>`).
   **Never `esearch -I` for this.** `-I` is `--instonly` — it lists only *installed* packages,
   so it returns 0 for every package you have not installed yet, including packages that are
   plainly in the tree. That reads as "not in the tree" and sends you off writing an
   unnecessary localrepo ebuild. (Recorded 2026-10-08: used `esearch -I gopass`, got 0,
   wrongly concluded the package was absent and the eix cache was stale; the package was
   `app-admin/gopass-1.15.15` in `::gentoo` and emerged fine. Also note `esearch` colourises
   its output, so `grep -oE "found : [0-9]+"` fails silently — pipe through `cat -A` or strip
   ANSI codes when parsing.)
2. **Check if already installed**: `qlist -I <package>` to see current version.
3. **Log the intent**: Before running emerge, append a structured entry to `package_history.log` in the workspace.
4. **Preview**: Always run `emerge -pv <package>` first to show the build plan — and read the
   **dependency list**, not just the package line. **One default USE flag can drag in a whole
   daemon.** `app-admin/logrotate` defaults to `USE=cron`, which pulls `cronie` + `cronbase` and
   installs a scheduler that did not exist before; `USE="-cron" emerge -pv <pkg>` shows the
   reduced plan (1 package instead of 8) before you commit to it. When you take the override,
   persist it in `/etc/portage/package.use/<pkg>` so a later `@world` update does not quietly
   reintroduce the dependency.
5. **Execute emerge**: Run `sudo emerge -av <package>` (with the same USE override you previewed).
6. **Verify and log outcome**: Confirm success/failure and update the log.

## Verifying ownership: `qfile` and `equery belongs` give FALSE NEGATIVES on merged-usr

Asked to prove a tool was installed via Portage ("keep it only if it came from portage"), the reflex is
`qfile -q /usr/bin/<bin>` or `equery belongs`. **Both report `<not owned by any package>` for packages
that Portage definitely installed**, because they resolve the path you handed them and merge-usr means
`/usr/bin/<bin>` and `/usr/sbin/<bin>` are the same inode via symlink — while the package's recorded
`obj` path may be only one of the two. On this box that produced three false "unowned" verdicts for
`hostapd`, `dnsmasq` and `tcpdump` in a single check, seconds after `qlist -I` had listed all three as
installed. Do not report "manually installed" on that evidence.

**Three checks, in order of trust:**

```bash
# 1. Is it installed at all? (the reliable headline)
qlist -I <category>/<package>     # or: qlist -Iv ... to also show USE flags

# 2. AUTHORITATIVE ownership — read the package's own contents database
d=$(ls -d /var/db/pkg/<category>/<package>-* | head -1)
grep -E '^obj /usr/(s)?bin/' "$d/CONTENTS"

# 3. Which binary is where
command -v <bin>
```

Step 2 is the one to quote. Note `dnsmasq` and `tcpdump` install to **`/usr/sbin`**, not `/usr/bin` — a
`grep '^obj /usr/bin/'` over their CONTENTS legitimately finds nothing, which reads exactly like a
failing package and is not one. Grep for both directories before concluding.

**A distro-built binary is not automatically the package's:** `aircrack-ng` owns `/usr/bin/aircrack-ng`
and `/usr/bin/airdecap-ng`, and `equery belongs` resolved those correctly while failing on the other
three — so a positive result is trustworthy and a negative is not. Asymmetry, not a coin flip.

**Close the audit trail in the same turn.** An entry left as `PENDING` in `package_history.log` is an
unfinished record, and the next session reads it as an install that may not have completed. Update it
to `SUCCESS`/`FAILED` as part of the install, not later. A batch fix is fine:

```bash
python3 - <<'PY'
p = "/home/carl/.hermes/package_history.log"
s = open(p).read(); n = s.count("| install | PENDING |")
open(p, "w").write(s.replace("| install | PENDING |", "| install | SUCCESS |"))
print(f"updated {n} entries")
PY
```

## Workflow — System Update

1. **Sync tree**: `sudo emerge-webrsync` (user's preferred method, uses snapshot from distfiles.gentoo.org).
2. **Dry-run**: `emerge --pretend --verbose --update --deep --with-bdeps=y --newuse @world` to see the scope.
3. **Check for REQUIRED_USE conflicts**: Look for unmet REQUIRED_USE constraints. Common cause: packages that don't support `python3_14` (the profile default). Options:
   - Fix USE flags with `/etc/portage/package.use/<pkg>` if the package is needed
   - Remove the package with `sudo emerge --deselect <pkg>` then `sudo emerge --depclean <pkg>` if it's not needed
   - Always show the user the options and let them decide
4. **Execute**: `sudo emerge --update --deep --with-bdeps=y --newuse @world` (with `-a` for confirmation).
5. **Config file updates**: `sudo dispatch-conf` to handle any updated config files.
6. **Clean up**: `sudo emerge --depclean` to remove orphaned deps.
7. **Reverse deps**: `revdep-rebuild` if any core libraries changed.

## Workflow — Remove a Package

1. **Check reverse deps**: `emerge --pretend --depclean <pkg>` to see if anything else needs it.
2. **Deselect from world**: `sudo emerge --deselect <package>` removes it from the @world set.
3. **Depclean**: `sudo emerge --depclean <package>` unmerges it.
4. **Verify**: `qlist -I <package>` should return nothing.

## Binary Package Setup

The Gentoo binhost provides prebuilt `.gpkg.tar` binaries for amd64 and arm64.

### Architecture Detection

```bash
grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E "avx2|bmi2|fma"
# All 3 present → x86-64-v3. Otherwise → x86-64.
```

### Configuration (one-time)

1. **Set up binrepos.conf**: `/etc/portage/binrepos.conf/gentoo.conf`
   ```
   [gentoo]
   priority = 9999
   sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3
   verify-signature = true
   location = /var/cache/binhost/gentoo
   ```
   Use `x86-64-v3` if the CPU supports AVX2+BMI2+FMA. Fall back to `x86-64` otherwise.

2. **Enable in make.conf**: Add `getbinpkg` to `FEATURES`:
   ```
   FEATURES="... getbinpkg"
   ```
   Add `binpkg-request-signature` ONLY if you're prepared to deal with the GPG trust chain (see pitfalls below). Without it, binaries still download and verify — the sig check just doesn't reject on trust level.

3. **Set up GPG trust**: `sudo getuto`

4. **PATCH the GPG permissions** (CRITICAL — getuto leaves them wrong):
   ```bash
   sudo chown -R portage:portage /etc/portage/gnupg
   sudo chmod 700 /etc/portage/gnupg
   ```
   Without this, every binary package fails with `unsafe ownership on homedir` and `Permission denied`. emerge runs GPG as the `portage` user, so the homedir must be owned by `portage:portage` with `700` permissions.

5. **Verify**: `emerge --pretend --update --deep --with-bdeps=y --newuse @world`

### Pitfalls (hard lessons)

**1. GPG homedir permissions MUST be corrected after getuto**
getuto creates `/etc/portage/gnupg` owned by `portage:portage` with group-write perms. GPG refuses to use a homedir that's group-writable:
```
gpg: WARNING: unsafe ownership on homedir '/etc/portage/gnupg'
gpg: failed to create temporary file '/etc/portage/gnupg/.#lk...': Permission denied
gpg: keyblock resource '/etc/portage/gnupg/pubring.kbx': Permission denied
```
**Fix**: `sudo chown -R portage:portage /etc/portage/gnupg && sudo chmod 700 /etc/portage/gnupg`

**1b. Even with permissions fixed, emerge runs GPG as nobody**  
Portage's `make.globals` hardcodes `GPG_VERIFY_USER_DROP="nobody"` and `GPG_VERIFY_GROUP_DROP="nogroup"`. This means GPG runs as `nobody:nogroup` during binary package verification. The `nobody` user cannot write lock/temp files in the keyring, so verification fails even with correct ownership.

**Symptoms:**
```
gpg: failed to create temporary file '/etc/portage/gnupg/.#lk...': Permission denied
gpg: keyblock resource '/etc/portage/gnupg/pubring.kbx': Permission denied
```

**Two fixes:**
- **Make world-writable** (pragmatic, preserves nobody drop): `sudo chmod -R o+w /etc/portage/gnupg`
- **Disable the nobody drop** (cleaner): Add to `make.conf`:
  ```
  GPG_VERIFY_USER_DROP=""
  GPG_VERIFY_GROUP_DROP=""
  ```

**3. `binpkg-request-signature` rejects good signatures on trust level**
Even with correct permissions and imported keys, GPG's trust model marks the automated binhost signing key as `TRUST_UNDEFINED`. emerge with `binpkg-request-signature` rejects it:
```
GOODSIG ... VALIDSIG ... TRUST_UNDEFINED
WARNING: This key is not certified with a trusted signature!
!!! Invalid binary package
```
The signature IS cryptographically valid — the issue is trust, not integrity. Fixes:
- **Easy**: Drop `binpkg-request-signature` from FEATURES. Binaries still download and verify, but won't be rejected. This is the pragmatic choice.
- **Hard**: Use `gpg --edit-key` to set trust to `5` (ultimate) on the binhost signing key, requiring interactive mode.

**3. GPG temporarily runs as nobody during verification**
Portage's `make.globals` sets `GPG_VERIFY_USER_DROP="nobody"` and `GPG_VERIFY_GROUP_DROP="nogroup"`. This means GPG runs as `nobody` which can't write lock/temp files even when the keyring is owned by `portage`. The `chmod 700` fix (pitfall #1) doesn't solve this on its own because the nobody user still can't write.

Workaround used successfully: make the keyring world-writable AND add a `gpg.conf`:
```bash
sudo chmod -R o+w /etc/portage/gnupg
sudo tee /etc/portage/gnupg/gpg.conf << 'EOF'
no-random-seed-file
keyid-format 0xLONG
with-fingerprint
EOF
```
The GnuPG docs accept `no-random-seed-file` as safe for non-generating use — verification is read-only.

**4. Always clear stale cached binaries after fixing GPG**
If emerge downloaded a `.gpkg.tar` and it failed verification, it won't re-download it on retry. The stale cached binary keeps failing:
```bash
sudo rm -f /var/cache/binhost/gentoo/**/*.gpkg.tar
```

**5. REQUIRED_USE conflicts often mean the user wants to remove the package**
When a package has unmet REQUIRED_USE (common with PYTHON_SINGLE_TARGET changes), present both options: fix USE flags vs remove the package. This user consistently prefers removal over wrestling USE overrides. Always ask, but lead with removal.

**6. Some packages are NOT in Portage — install via upstream script**
Ollama is the canonical example on this box: installed via the upstream install script, not Portage (`curl -fsSL https://ollama.com/install.sh | sh`). The live ebuild in the tree is orphaned and unmaintained. Re-run the script to update. The systemd unit (`ollama.service`) is managed by the script, not emerge, so it doesn't show up in `qlist` — but `/usr/local/bin/ollama` and `/usr/share/ollama/` are the install locations. Before reaching for an ebuild, check if the package is actually maintained in the tree (`esearch -I <pkg>` may return a hit even when the live ebuild is abandoned — look for `LIVE` in `equery m <pkg>` or open the ebuild and check for `EAPI=` + last `EGIT_COMMIT`).

### Kernel source updates

If the update pulled in new `sys-kernel/gentoo-sources` into a new slot, the user may want to rebuild the kernel to pick up security fixes. See the `gentoo-kernel-build` skill for the full workflow.

### Qt slot cleanup after upgrade

`emerge --depclean` often fails because old Qt6 packages (qtbase, qtdeclarative, qttools, etc.) remain installed alongside the new ones. The old slot blocks depclean because old versions of other Qt packages still depend on it.

Check for multi-slot packages:
```bash
qlist --slots dev-qt/qtbase
# Should show only the new slot (e.g. dev-qt/qtbase:6)
# If an old version is detected:
sudo emerge --unmerge dev-qt/qtbase-<old-version>
```

Then run preserved-rebuild again (old libs will force rebuild of packages that linked against them). Also check for other Qt packages:
```bash
equery list dev-qt/qtdeclarative dev-qt/qttools dev-qt/qtmultimedia
```

If any show old versions, rebuild against the new slot:
```bash
sudo emerge --oneshot dev-qt/qtdeclarative dev-qt/qttools dev-qt/qtmultimedia dev-qt/qt5compat
```

### Kernel source Makefile may be missing after a kernel build

The running kernel config is in `/proc/config.gz`, but the Makefile is not critical for boot — only for tools that need to determine the kernel version at build time (like Chrome's `chrome-sandbox`). See `references/kernel-source-makefile.md` for diagnosis and fix.

---

## Pitfall: ebuilds that ship a config file overwrite the user's real values

When bumping an ebuild whose `src_install` writes a config file (e.g.
`newins "${FILESDIR}/api_key" api_key` into `/etc/fdc/`), the upgrade
stages a `. _cfg0000_<name>` file and Portage flags it as a protected
config needing `dispatch-conf`. The staged file is the **default** from
the ebuild — it will clobber a real value the user set (e.g. a real API
key replacing `DEMO_KEY`).

**Do NOT blindly run `dispatch-conf` / accept the new config.** Check
what changed first:

```bash
sudo ls -la /etc/fdc/                 # look for ._cfg0000_* files
sudo cat /etc/fdc/api_key             # current (real) value
sudo cat /etc/fdc/._cfg0000_api_key   # staged default from ebuild
```

If the user's real value differs from the staged default, **keep the
real one and delete the staged file**:

```bash
sudo rm -f /etc/fdc/._cfg0000_api_key
```

This is the same class of issue as `dispatch-conf` on any protected
config — always diff before accepting. Recorded 2026-08-16: bumping
`app-misc/fdc` 1.0.0→1.1.0 staged `DEMO_KEY` over the user's real FDC
API key; kept the real key, removed the staged file.

### The staged set is not only the package you just merged — audit all of it

`emerge` reports the total: *"N config files in /etc need updating"*. That set can include files
staged by **earlier** merges, unrelated to the package you just installed, and they can sit there
for weeks. A blanket `dispatch-conf` accept destroys whatever real values they still hold.

Audit every entry before touching any:

```bash
sudo find /etc -maxdepth 3 -name '._cfg*'                 # the whole staged set
sudo diff -u /etc/<target> /etc/<dir>/._cfg0000_<name>    # current vs staged, per file
```

Decide per file: keep the real value and delete the staged file, merge by hand, or accept only
when the staged version is genuinely a newer default and nothing user-set is lost. Values worth
guarding on sight: **service secrets and keys**, **host entries** (`/etc/hosts`), and **hardware
identifiers** (`DefaultAdapter=` and similar).

### Installing a package can arm hooks that were inert

A shipped `/etc/cron.daily/*` or `/etc/logrotate.d/*` file does nothing until the tool that runs
it exists. Installing that tool starts applying them to **other services' files**. Before enabling
it, read each inherited config and check it is correct for the service it points at — an inherited
entry with no log-reopen path will silently orphan a daemon's log on its first rotation.

## Tips

- **`gentoo-kernel-build`** — After a system update that pulls in new kernel sources, this skill handles safe build, install, and GRUB-configured fallback boot for headless systems.

## Log Format

Every installation attempt produces a log entry in `package_history.log` with:
- Timestamp (ISO 8601)
- Package name and version
- Action taken (install / update / sync)
- Outcome (SUCCESS / FAILED)
- Command executed

## Safety Guidelines

- **Stability First**: Never install a package that would replace core system libraries without explicit user consent.
- **World updates are OK** with proper preparation: always dry-run first, fix any REQUIRED_USE conflicts, and present the full scope to the user before executing.
- **Explain before installing**: Show the user what will be installed and why before executing.
- **Use `-pv` for review**: Always use `--pretend --verbose` (`-pv`) to show the build plan before real execution.
- **No `--ask` in non-interactive contexts**: `--ask` / `-a` requires a TTY and exits immediately when running from a cron job or agent terminal. Use `--pretend` first for review, then run the real emerge WITHOUT `--ask`.
- **No `--nodeps`**: Never skip dependency resolution unless explicitly told to.
- **`--usepkgonly`/`-K`** is too restrictive — prefer `getbinpkg` feature + fallback to source when no binary matches USE flags.

## User workflow pattern (Joerg, 2026-07-15)

When the user has already told you the plan ("install X", "do the install", "fine-tune a piper voice", "install via portage", "use lessac-medium for warmstart"), **execute it.** Don't come back with another "shall I?" or "do you want to confirm?" — Joerg is on record preferring terse action. The split is:

- First mention of a task → brief plan + ask if it has hidden decisions (e.g. "lessac-medium vs ljspeech-medium warmstart" — that *is* a real decision).
- "Do the install / do the work / proceed / go" → execute top-to-bottom, log the outcome, report at the end.

The plan and the execute are not separate conversations. If the user said "install X", they want X installed, not another confirmation round. This applies to ebuild work, training launches, package installs, and the Piper environment setup workflow in particular.

## Commands

Common operations:
```bash
# Search the tree for a package (NOT `esearch -I` — that is --instonly, installed only)
esearch <package>

# Preview an installation (always do this first)
emerge -pv <package>

# Install a package
emerge -av <package>

# Sync the Portage tree
emerge --sync

# Check package status
qlist -I <package>
```

## USE flag override for a single install (no `package.use` file)

When you need a USE flag for one specific rebuild — e.g. Pillow with
`truetype` for chart-rendering — without writing a permanent entry to
`/etc/portage/package.use/`, use the `USE=...` prefix on the emerge
command:

```bash
sudo USE="truetype" emerge --verbose dev-python/pillow
```

The flag is applied only for this one emerge. Subsequent emerge runs
without the prefix use the package's default USE config. This is the
right tool when:

- You want to test whether a USE flag fixes a problem before committing
  to it permanently
- The flag is for a one-off task (a script you'll run once)
- Adding to `package.use` would force a rebuild of reverse deps you
  don't want to rebuild

**Verify the flag was applied:**

```bash
qlist -v dev-python/pillow | head -1
# USE flags column should now include "truetype"
# Or: equery u dev-python/pillow
```

Recorded 2026-07-12: rebuilt `dev-python/pillow` with `truetype` to
get a working `PIL.ImageFont.truetype()` (the default build on this
box was missing the freetype backend, so PIL could load images but
not render text — silent failure with `ImportError: cannot import
name '_imagingft'`).

## Environment

- User is a member of the `portage` group (gid 250).
- Work as the `openclaw` user (uid 997).
- Use `sudo -E` or host-level sudo only when explicitly required by emerge.