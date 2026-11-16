# Service accounts as Portage packages (acct-user / acct-group)

How to give a daemon its own unprivileged user on this box. **Never `useradd` an
account for a service** — an account created by hand is unmanaged, invisible to
`emerge -C`, and forgotten exactly like a loose file in `/usr/local/bin`.

## Check for an existing instance FIRST

Before designing anything, grep the overlay for the pattern you are about to
invent — a convention already implemented here is the specification:

```bash
find /var/db/repos/localrepo -path '*/acct-*/*' -name '*.ebuild'
qlist -Iv | grep ^acct-
```

Read the existing one and follow it. On this box that is `acct-group/searxng` +
`acct-user/searxng` — copy their shape, and take the next free ID nearby.

## ID allocation

Pick an ID not in use, in the range the existing localrepo accounts occupy; check
both databases before choosing:

```bash
getent group | awk -F: '$3>=395 && $3<=460 {print $3, $1}' | sort -n
getent passwd | awk -F: '$3>=395 && $3<=460 {print $3, $1}' | sort -n
```

Give the user and group the **same** ID, and keep service accounts out of
`SYS_UID_MIN..MAX` only if the local convention already does — follow the
neighbouring precedent rather than the eclass default.

## The two ebuilds

`acct-group/<name>/<name>-0.ebuild`:

```bash
# Copyright <year> Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit acct-group

DESCRIPTION="System group for <Service>"

ACCT_GROUP_ID=<NNN>
```

`acct-user/<name>/<name>-0.ebuild`:

```bash
EAPI=8

inherit acct-user

DESCRIPTION="System user for <Service>"

ACCT_USER_ID=<NNN>
ACCT_USER_GROUPS=( "<name>" )
ACCT_USER_HOME=/var/lib/<name>
ACCT_USER_HOME_OWNER="<name>:<name>"
ACCT_USER_SHELL=/sbin/nologin
ACCT_USER_NO_MODIFY=1

acct-user_add_deps
```

`ACCT_USER_SHELL` defaults to `/sbin/nologin` and `ACCT_USER_HOME` to `/dev/null`;
state them explicitly anyway — the default for HOME is `/dev/null`, which is not
what a service wants. All four variables are real eclass variables (grep
`/var/db/repos/gentoo/eclass/acct-user.eclass` to confirm before inventing one).

## Shipping them

The normal pipeline applies (see the parent skill), with three differences:

1. **No `SRC_URI`, no `files/`.** These packages ship no data at all.
2. **`pkgdev manifest` reports "manifests are up to date"** and writes nothing —
   there are no sources to hash. That is correct, not a failure.
3. **`pkgcheck scan` exits 0 but emits `PotentialStable`** on both packages. This is
   an informational notice on acct packages (the existing `searxng` pair carries it
   too) — not a warning to fix.

The install phase still needs root (`chown` on the image dir):

```bash
sudo ebuild ./<name>-0.ebuild clean test install
sudo emerge -v acct-group/<name> acct-user/<name>
```

`emerge` prints `* Adding group <name>` / `* Adding user <name>` from the eclass.

## Verify the account is real and minimal

```bash
getent passwd <name>                     # uid, shell, home
getent group  <name>                    # gid
getent group <name> | cut -d: -f4       # members — expect EMPTY (least privilege)
ls -ld /var/lib/<name>                  # owned by the new account
qcheck acct-user/<name> acct-group/<name>
```

Leave the group with **no members**. Adding members later is a deliberate act;
adding them now is accidental privilege.

## What a service account does NOT do by itself

Switching a unit's `User=` to the new account is a **separate change**, and on this
box it is a project rather than an edit. Every one of these blocks it, and each is
its own work item:

- **Anything the unit runs from the operator's home is unreadable.** `/home/<operator>`
  is mode `700`, so binaries, venvs, and helper scripts under it become unreachable.
  The trees must move to a shared location, or the account needs ACLs.
- **A `ExecStartPre` that reads the operator's secret store breaks** — gopass is
  unlocked by that user's GPG key, so a service user cannot read it. Split the step
  out, or move the credential.
- **Every backend the service spawns inherits the restriction.** If the daemon spawns
  subprocesses that read config from the operator's home, each one is a separate fix.
  Enumerate them before promising the cutover.
- **Do the cutover one backend at a time**, verifying each, rather than flipping the
  whole service at once. Same discipline as a credential migration.

Say this plainly when asked to create the account: the account is the easy half, and
the cutover is what it is FOR. Creating the account and stopping is a valid, complete
deliverable — do not silently proceed into the cutover.
