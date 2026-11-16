# Gentoo Binary Package Host Setup — Reference

## Architecture Detection

```bash
grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E "avx2|bmi2|fma"
# If all 3 present → x86-64-v3. Otherwise → x86-64.
```

## /etc/portage/binrepos.conf/gentoo.conf

**x86-64-v3** (i7-10700T, Comet Lake and newer):

```
[gentoo]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3
verify-signature = true
location = /var/cache/binhost/gentoo
```

**Standard x86-64** (older CPUs without AVX2):

```
[gentoo]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64
verify-signature = true
location = /var/cache/binhost/gentoo
```

## make.conf Changes

Add to `FEATURES`:
```
FEATURES="... getbinpkg"
```

`binpkg-request-signature` is OPTIONAL and problematic — see Pitfalls below.

## GPG Trust

```bash
sudo getuto
```

Run once after binrepos.conf is set up. Configures the Gentoo Trust Tool keyring under `/etc/portage/gnupg/`.

## Permission Fix (Required After getuto)

getuto sets ownership to `portage:portage` with group-writable perms. GPG is strict about homedir permissions:

```bash
sudo chown -R portage:portage /etc/portage/gnupg
sudo chmod 700 /etc/portage/gnupg
```

## Nobody Drop Fix (Required for GPG Verify to Work)

Portage hardcodes `GPG_VERIFY_USER_DROP="nobody"` in `make.globals`. The `nobody` user cannot write lock/temp files even when the keyring ownership is correct.

**Fix A — disable the drop (cleaner):**
```bash
echo 'GPG_VERIFY_USER_DROP=""' >> /etc/portage/make.conf
echo 'GPG_VERIFY_GROUP_DROP=""' >> /etc/portage/make.conf
```

**Fix B — make keyring world-writable (preserves security drop):**
```bash
sudo chmod -R o+w /etc/portage/gnupg
```

Either fix must be combined with the gpg.conf `no-random-seed-file` directive below.

## GPG Config

Add a `/etc/portage/gnupg/gpg.conf` to suppress the random_seed write attempt (since nobody can't write it):

```ini
no-random-seed-file
keyid-format 0xLONG
with-fingerprint
```

## Pitfalls

### 1. GPG homedir permissions

getuto leaves `/etc/portage/gnupg` group-writable. GPG refuses group-writable homedirs → "unsafe ownership" + "Permission denied".

**Fix**: `chown -R portage:portage` + `chmod 700`.

### 2. binpkg-request-signature rejects on trust, not validity

The automated Gentoo binhost signing key (`2C44695DB9F6043D` / fingerprint `13EBBDBEDE7A12775DFDB1BABB572E0E2D182910`) produces `VALIDSIG` + `GOODSIG` but marks `TRUST_UNDEFINED`. emerge with `binpkg-request-signature` still rejects it:

```
!!! Invalid binary package: '.../util-linux-2.41.4-r1-10.gpkg.tar', GnuPG verification failed
```

The signature IS cryptographically valid — the issue is GPG's trust model, not integrity.

**Pragmatic fix**: Drop `binpkg-request-signature` from FEATURES. Binaries still download and signature verification still runs (it's logged), but the trust-level rejection is bypassed.

### 3. GPG runs as nobody during verification

Portage hardcodes `GPG_VERIFY_USER_DROP="nobody"` and `GPG_VERIFY_GROUP_DROP="nogroup"` in `make.globals`. This means GPG runs as the `nobody` user during binary package verification, which cannot write lock/temp files even when the keyring is owned by `portage`.

**Full fix used successfully**:
```bash
sudo chmod -R o+w /etc/portage/gnupg
sudo tee /etc/portage/gnupg/gpg.conf << 'EOF'
no-random-seed-file
keyid-format 0xLONG
with-fingerprint
EOF
```

### 4. Stale cached binaries don't get retried

If emerge downloaded a `.gpkg.tar` and it failed GPG verification, portage's cache preserves the downloaded file. On retry, emerge sees the file exists and doesn't re-fetch — so the same verification failure repeats.

**Fix**: `sudo rm -f /var/cache/binhost/gentoo/**/*.gpkg.tar` before retrying.

### 5. Mirror choice

The CDN (`distfiles.gentoo.org`) works well from Singapore — expect ~70-80 MB/s downloads over IPv6.

## Verification

```bash
# Check cached binhost packages
ls /var/cache/binhost/gentoo/

# Count binary vs source packages
emerge --pretend --update --deep --with-bdeps=y --newuse @world | grep -E "^\[binary|^\[ebuild" | awk '{print $1}' | sort | uniq -c | sort -rn
```

## Notes

- The binrepos.conf priority=9999 ensures the binhost is checked before any other package source.
- `--binpkg-respect-use=y` (default): only accept binaries with matching USE flags. Some packages compile from source if USE flags differ — this is expected.
- Packages with `getbinpkg` in FEATURES are pulled automatically. No need for `-g` flag on emerge.