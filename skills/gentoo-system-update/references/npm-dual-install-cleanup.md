# NPM Dual-Install Cleanup on Gentoo amd64

## The problem

On Gentoo amd64, `npm prefix -g` returns `/usr`, so `sudo npm update -g` writes updated packages to `/usr/lib/node_modules/`. But the active symlinks in `/usr/local/bin/` (and elsewhere) point to `/usr/lib64/node_modules/`. After an update, the old copies in `/usr/lib64/` remain active while the new copies sit in `/usr/lib/` — effectively a no-op update.

## Detection

```bash
# Check for dual install
ls -la /usr/lib/node_modules/
ls -la /usr/lib64/node_modules/

# Check which copy is actually active
which <pkg>
readlink -f $(which <pkg>)
<pkg> --version
```

If `readlink -f` resolves to `/usr/lib64/...` but the newer version is in `/usr/lib/...`, you have a dual install.

## Cleanup

```bash
# 1. Remove stale entries from /usr/lib/node_modules/ (the old install target)
sudo rm -rf /usr/lib/node_modules/*/

# 2. Verify the active symlinks still work
which npm
npm --version
which openclaw
openclaw --version
```

## Verification

After cleanup, `ls -la /usr/lib/node_modules/` should be empty (or contain only the `@` directory if empty). All active packages live under `/usr/lib64/node_modules/`.

## Root cause

`npm prefix -g` returns `/usr` on Gentoo, but the system's node_modules search path resolves to `/usr/lib64/` first due to multilib layout. The `sudo npm update -g` command writes to the prefix location, not the runtime location.
