# PyPI Wheel Bundling for Gentoo Ebuilds

When a PyPI package has dependencies that are not in Portage (common with
packages that pull 20+ language bindings, ML frameworks, or niche parsers),
writing individual ebuilds for every transitive dep is impractical. The
pragmatic Gentoo approach: bundle all wheels as a secondary distfile and
install offline during `src_install`.

## When to use this pattern

- The package is on PyPI and installs cleanly with `pip`
- Its dependencies include packages NOT in ::gentoo (e.g. 25+ tree-sitter
  language bindings, specialized ML wheels, proprietary SDKs)
- The user wants Portage lifecycle management (`emerge`, `emerge -C`, world file)
  without maintaining a parallel dep tree
- The package is a CLI tool (not a library others will import), so the venv
  isolation is acceptable

## Worked example: graphifyy 0.9.26 (2026-09-13)

graphifyy depends on networkx, numpy, rapidfuzz, tree-sitter, and 24
language-specific tree-sitter bindings. None of the tree-sitter language
packages are in Portage. The solution:

### 1. Download wheels offline

```bash
mkdir -p /tmp/graphifyy-wheels
python3 -m pip download graphifyy==0.9.26 -d /tmp/graphifyy-wheels
# Result: 28 .whl files including all transitive deps
tar czf graphifyy-deps-0.9.26.tar.gz -C /tmp/graphifyy-wheels .
```

### 2. Add the wheel tarball as a secondary distfile

In the ebuild:
```bash
SRC_URI="
    ${PYPI_SRC_URI}
    graphifyy-deps-${PV}.tar.gz
"
```

Or with explicit PyPI URL:
```bash
SRC_URI="
    https://files.pythonhosted.org/packages/source/g/graphifyy/graphifyy-${PV}.tar.gz
    graphifyy-deps-${PV}.tar.gz
"
```

Place `graphifyy-deps-0.9.26.tar.gz` in `${DISTDIR}` (`/var/cache/distfiles/`)
or let Portage fetch it from a mirror.

### 3. Unpack wheels in `src_unpack`

```bash
src_unpack() {
    default
    mkdir -p "${WORKDIR}/wheels" || die
    tar xzf "${DISTDIR}/graphifyy-deps-${PV}.tar.gz" -C "${WORKDIR}/wheels" || die
}
```

### 4. Install from wheels into a venv in `src_install`

```bash
src_install() {
    local venv="${ED}/opt/graphifyy"
    ${EPYTHON} -m venv "${venv}" || die
    "${venv}/bin/pip" install --no-index --find-links "${WORKDIR}/wheels" \
        "${WORKDIR}/wheels"/graphifyy-${PV}-py3-none-any.whl || die

    # Fix shebangs so they point to live path, not image path
    find "${venv}/bin" -type f -exec sed -i \
        "s|${ED}/opt/graphifyy/bin/python|/opt/graphifyy/bin/python|g" {} + 2>/dev/null || true

    fowners -R root:root /opt/graphifyy
    fperms -R a+rX /opt/graphifyy
    fperms a+x /opt/graphifyy/bin/graphify

    # Install a wrapper in /usr/bin
    newbin - graphify << 'WRAPPER'
#!/usr/bin/env bash
exec /opt/graphifyy/bin/graphify "${@}"
WRAPPER
}
```

### 5. The shebang fix is critical

Pip writes shebangs pointing at the python interpreter used during install.
During Portage's `src_install`, that path is the image dir
(`${ED}/opt/graphifyy/bin/python3.14`), not the live path
(`/opt/graphifyy/bin/python3.14`). Without the sed fix, the installed binary
fails with:
```
bad interpreter: /var/tmp/portage/dev-util/graphifyy-0.9.26/image/opt/graphifyy/bin/python3.14: No such file or directory
```

Fix: replace `${ED}`-prefixed paths with live paths before the image is merged.
Match only the `${ED}`-prefixed form in the sed pattern — a broad
`s|/opt/graphifyy|/opt/graphifyy|` no-op or an over-broad pattern that also
rewrites unrelated paths can corrupt other scripts in `bin/`.

**Smoke-test the binary from the IMAGE dir (as root, since image files are
root-owned 0700), not from `/opt` — `/opt` doesn't exist yet pre-merge.**
`sudo /var/tmp/portage/.../image/opt/graphifyy/bin/graphify --version` →
`graphify 0.9.26`. A "Permission denied" on the image binary is expected for
non-root and is NOT the shebang bug — verify the interpreter path with `head
-1` on the script instead.

### 5b. The packaged venv is MINIMAL — runtime LLM deps are NOT included

The wheel bundle covers only what `pip download graphifyy` resolves (its
declared deps). The packaged CLI (`/usr/bin/graphify`, venv at
`/opt/graphifyy`) runs fine for `path`/`explain`/`cluster-only`, but
**LLM-backed features need `openai` too** — graphify's provider layer imports
it even when the backend is ollama. `openai` isn't a graphifyy dependency, so
it's absent from the bundle. Symptom: an agent (Kiko) loops trying
`pip install openai` inside the root-owned venv and fails with permission
denied; the fix is one manual command:
```bash
sudo /opt/graphifyy/bin/pip install openai
```
Note this makes the live install drift from the ebuild — if you re-emerge,
either add `openai` to a `pkg_postinst` pip-install step or re-download a
wheel bundle that includes it. Document any such post-install pip additions
in the ebuild's `pkg_postinst` elog so the next re-emerge doesn't silently
break LLM features again.

**Agent-side guidance for root-owned venvs:** when an agent (Kiko) reports
"can't pip install into /opt/... without root", the fix is a single
`sudo <venv>/bin/pip install <pkg>` from the admin side — not an ebuild
change, not a rebuild. Don't tell the agent to keep retrying; intervene
directly and verify the import works (`<venv>/bin/python -c "import openai"`).

### 6. Register in the localrepo

```bash
echo "dev-util/graphifyy ~amd64" | sudo tee /etc/portage/package.accept_keywords/zz-localrepo
sudo emerge -v =dev-util/graphifyy-0.9.26
```

## Key differences from a normal source ebuild

| Aspect | Normal source ebuild | Wheel-bundled ebuild |
|---|---|---|
| `RDEPEND` | Lists all runtime deps | Minimal — just `${PYTHON_DEPS}` |
| `BDEPEND` | Build tools (setuptools, etc.) | Empty or minimal |
| `src_compile` | Actual compilation | No-op (`:`) |
| `src_install` | `dobin`, `dolib`, etc. | `pip install --no-index` into venv |
| Distfiles | Source tarball only | Source tarball + wheel bundle tarball |
| Network during emerge | Fetches source | None (offline install) |

## Pitfalls

- **Wheel ABI mismatch:** If the build host Python differs from the target,
  wheels with C extensions (`.so` files) may fail. Download wheels for the
  target Python version, or use `abi3` wheels when available.
- **Missing `metadata.xml`:** `pkgcheck` requires a valid `metadata.xml` with
  `<maintainer>` email containing a dot (e.g. `carl@gentoo.local`).
- **`pkgcheck` warnings:** `EmptyGlobalAssignment` on `BDEPEND=""` — omit the
  line entirely. `WhitespaceFound` — strip leading whitespace from ebuild lines.
  These are cosmetic but should be fixed for clean QA.
- **Manifest generation:** Both distfiles (source + wheels) must be in the
  Manifest. Run `pkgdev manifest` after staging both files in `${DISTDIR}`.

## Verification

After installation, confirm cross-user accessibility:
```bash
which graphify          # should be /usr/bin/graphify
graphify --version      # should work as root, carl, and openclaw
```

## Related

- Parent skill `localrepo-ebuild-shipping` for the full localrepo pipeline
- `references/pure-python-ebuild.md` for the simpler case where deps ARE in Portage
- `references/pip-wheel-data-sandbox-fix.md` for pip wheel `.data/data` sandbox violations
