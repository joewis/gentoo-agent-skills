# Binary Python Wheel Ebuild (manylinux wheel from PyPI)

For Python packages that ship pre-built manylinux wheels (bundling C extensions) and have pip dependencies not available in Gentoo repos — piper-tts and onnxruntime are the archetypes.

## When to use this pattern

- Package provides a manylinux wheel on PyPI (`.whl`)
- Wheel bundles C/C++ extensions (e.g. `espeakbridge.so`) + data files
- pip dependencies of the wheel (e.g. `onnxruntime`, `pathvalidate`) may or may not be in Gentoo
- Building from source would require network access during build (cmake ExternalProject, git fetches)

## Technique: SRC_URI pointing at the PyPI wheel

Get the wheel URL from PyPI JSON API (not files.pythonhosted.org directly — the hash segment is non-obvious):

```bash
curl -sL "https://pypi.org/pypi/<package>/<version>/json" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for url_info in d['urls']:
    if url_info['packagetype'] == 'bdist_wheel' and 'manylinux' in url_info['filename'] and 'x86_64' in url_info['filename']:
        print(url_info['url'])
"
```

For a specific python version, filter more precisely (e.g. `'cp314-cp314' in f` and `'t' not in f.split('-')[2]` to exclude free-threaded builds).

## Ebuild Template

```bash
# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Short description of the package"
HOMEPAGE="https://github.com/org/repo"
SRC_URI="
	https://files.pythonhosted.org/packages/XX/YY/<hash>/<package>-${PV}-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.manylinux_2_28_x86_64.whl
"

S="${WORKDIR}"

LICENSE="MIT"  # or whatever the license is
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="test mirror strip"

# RDEPEND: only declare Gentoo-available deps.
# If the wheel's pip dep is also in the localrepo as a wheel ebuild,
# declare it here (e.g. sci-libs/onnxruntime).
RDEPEND=""
BDEPEND="dev-python/pip"

src_unpack() {
	mkdir -p "${S}" || die
	cp "${DISTDIR}/$(ls ${DISTDIR} | grep ${PN}.*.whl)" "${S}/" || die
}

src_compile() {
	:
}

src_install() {
	pip install \
		--no-build-isolation \
		--no-deps \
		--no-index \
		--progress-bar off \
		--root="${D}" \
		--prefix="${EPREFIX}/usr" \
		"${S}"/*.whl 2>&1 || die "pip install failed"
}
```

## Adding a new category

When the package category doesn't exist yet in `/etc/portage/categories` (e.g. `sci-libs`, `app-text`), add it:

```bash
echo "<category>" | sudo tee -a /etc/portage/categories
```

## pkgcheck: expected warnings you can ignore

- **MissingRemoteId**: Add `metadata.xml` with `<remote-id type="github">org/repo</remote-id>` to clear it.
- **EmptyGlobalAssignment** (`RDEPEND=""`): Remove the `=""` — just omit the line entirely, or don't set it if there are no RDEPENDs.
- **VariableOrderWrong**: S must come immediately after SRC_URI, before LICENSE.
- **NonsolvableDeps**: For musl/dev profiles that don't have your python targets. Harmless in an overlay.

## Pitfalls

- **PYTHON_SINGLE_TARGET / python-single-r1 complexity**: Avoid inheriting `python-single-r1` unless the ebuild actually needs it. If the wheel uses the ABI3 stable ABI (cp39-abi3), it works with any Python ≥3.9 without needing PYTHON_TARGETS. Only add it if you have a Gentoo RDEPEND that needs `[${PYTHON_SINGLE_USEDEP}]`.

- **The `python-single-r1` hard fail**: If you *do* use `python-single-r1`, Portage's dependency solver checks that ALL deps are built with the same `python_single_target`. If a dep exists but was built with different targets, you get `emerge: there are no ebuilds built with USE flags to satisfy "pkg[python_single_target_XYZ]"` — even though the dep IS installed. The fix is to either (a) drop `python-single-r1` and use bare package names, or (b) match PYTHON_COMPAT exactly to what's available.

- **onnxruntime**: Not available in Gentoo proper. If you want it as a Gentoo dependency, create a `sci-libs/onnxruntime` ebuild following this same wheel pattern. Version-specific: the wheel filename includes the Python version (e.g. `cp314-cp314`), so you need a separate ebuild per Python version or use the `cp39-abi3` variant if it exists.

- **QA warnings about missing opt-1/opt-2 pyc files**: These come from pip skipping bytecode optimization. They're harmless cosmetic warnings from the Gentoo QA scanner. Ignore them.

- **DISTDIR filename mismatch**: The wheel filename in DISTDIR may differ from SRC_URI if you use `${PV}` in the filename. Use `ls | grep` to find it dynamically in `src_unpack`, or hardcode the exact filename.

- **/usr/COPYING QA notice**: Some wheels include a `COPYING` file at the wheel root, which pip installs to `/usr/`. This is a wheel layout issue, not an ebuild bug. Can be silenced with `rm "${D}/COPYING"` in `src_install` if desired.

- **keywords file**: Create a file under `/etc/portage/package.accept_keywords/` for each new package: `echo "=cat/pkg-version ~amd64" | sudo tee /etc/portage/package.accept_keywords/<name>`.

- **Always test the import**: After emerging, run `python3 -c "import pkgname"` to verify the wheel actually works. Some wheels have runtime deps (like onnxruntime needing numpy) that won't be caught until actual use.
