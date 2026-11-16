# Gentoo agent skills

Four agent skills for working on a Gentoo box: keeping it updated, writing ebuilds, shipping
them through a local overlay, and installing packages safely.

They are plain `SKILL.md` files with YAML frontmatter plus supporting `references/` and
`scripts/` directories — the format used by Hermes Agent, and close enough to Claude Code's
skill format to be adapted by copying. Each one is loaded when the agent decides it is
relevant, so the pitfalls below are available at the moment they matter rather than sitting in
a prompt all the time.

| Skill | Lines | What it covers |
|---|---|---|
| `emerge-steward` | 388 | The policy layer: how packages get installed, binhost/`.gpkg.tar` setup, GPG verification traps, config-file protection |
| `gentoo-system-update` | 267 | The update routine: sync, portage self-update, the autounmask loop, depclean safety, cleanup, cron mode |
| `write-ebuild` | 1049 | Authoring: skeleton, variables, phases, dependency atoms, eclasses, worked templates per build system, pkgcheck reference |
| `localrepo-ebuild-shipping` | 1083 | Shipping: source-vs-binary decision, permission model, manifest→QA→test→emerge→push pipeline, version bumps, licensing |

## Why these exist

Most Gentoo knowledge online is correct about the happy path and silent about the second
failure. The value here is in the failure modes, each of which cost real time and is written
down with the command that diagnosed it and the fix that worked. A sample:

- `emerge --depclean` can select the **active** `sys-devel/gcc` slot for removal. Portage does
  not know which slot `gcc-config` points at; it keeps the newest and drops the rest. Check
  `gcc-config -c` against the depclean preview before running it.
- A depclean complaint about a "missing" library is usually a **stale subslot** recorded at
  build time. Rebuilding the library changes nothing; rebuild the consumer so it re-records
  `pkg:slot/subslot=`.
- `emerge -vu @world` exiting 1 with a USE/keyword/mask request is the normal failure mode of a
  large update, not a broken package. Add the one line it asked for and re-run **pretend** — not
  emerge — because there may be several requests in sequence.
- A `SRC_URI` whose basename has no version number keeps hashing the **old cached bytes** across
  version bumps. The ebuild builds and installs the previous version, and `pkgdev manifest` will
  report "up to date" while holding the wrong hash.
- A `9999` live ebuild silently **shadows** a versioned one: `9999` sorts highest, so a pin in
  your versioned ebuild is inert and every merge reinstalls latest.
- `qfile` and `equery belongs` give **false negatives** on merged-usr systems, reporting
  "not owned by any package" for packages Portage definitely installed. Read the package's own
  `CONTENTS` file instead.

## Installing

Copy a skill directory into your agent's skill path:

```bash
cp -r skills/write-ebuild ~/.hermes/skills/          # Hermes Agent
cp -r skills/write-ebuild ~/.claude/skills/          # Claude Code, same layout
```

Nothing here is executable on its own. `gentoo-system-update/scripts/gentoo-update-preflight.sh`
is a template you copy into your own scripts directory, and
`localrepo-ebuild-shipping/scripts/backend_dep_audit.py` is a helper you run by hand.

## Caveat: these were written against one machine

The procedures are general; the paths and conventions are not. Before using them you will want
to change:

- `/var/db/repos/localrepo` if your overlay lives elsewhere, and the `joewis/localrepo` mirror
  references in the shipping skill
- user names (`carl`, `portage`, `openclaw`) and home paths
- the binhost profile in `emerge-steward` (`default/linux/amd64/23.0/systemd`, x86-64-v3)
- the kernel/package specifics that reflect one box's history

Treat them as worked examples with the reasoning left in, not as a drop-in configuration.

## Safety

`gentoo-system-update` includes `emerge --depclean`, which removes packages. It documents how to
read the preview and what Portage gets wrong, but the decision is still yours — read the preview
before confirming, every time. Nothing here should be run unattended on a system you cannot
recover.

## License

MIT — see `LICENSE`.
