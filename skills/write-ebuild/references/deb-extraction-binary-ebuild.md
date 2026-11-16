# Binary Ebuild from .deb / .rpm Packages

When upstream only offers `.deb` or `.rpm` packages (not standalone tarballs), extract the binary and bundled dependencies from the package archive.

## Extraction (manual inspection)

```bash
# Download the .deb
wget https://example.com/downloads/package_1.0.0_amd64.deb

# Extract (two methods)
# Method A: ar + tar
ar x package_1.0.0_amd64.deb
tar xf data.tar.gz
# or data.tar.xz

# Method B: dpkg-deb (if available on Gentoo)
dpkg-deb --extract package_1.0.0_amd64.deb ./extracted
```

Inspect what's inside:

```bash
file extracted/opt/package/bin/package-binary
ldd extracted/opt/package/bin/package-binary
```

## Ebuild Pattern

```bash
# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Proprietary application — only available as .deb"
HOMEPAGE="https://example.com/download"
SRC_URI="https://example.com/downloads/${PN}_${PV}_amd64.deb -> ${P}.deb"

LICENSE="all-rights-reserved"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="bindist mirror strip"

RDEPEND="
    sys-libs/glibc
    dev-libs/openssl:=
"

S="${WORKDIR}"

src_unpack() {
    default  # Portage unpacks .deb via ar + tar

    # Determine where files ended up — varies by .deb
    if [[ -d "${WORKDIR}/opt/${PN}" ]]; then
        S="${WORKDIR}/opt/${PN}"
    elif [[ -d "${WORKDIR}/opt" ]]; then
        S="${WORKDIR}/opt"
    else
        S="${WORKDIR}"
    fi
}

src_compile() {
    :
}

src_install() {
    insinto "/opt/${PN}"
    doins -r "${S}"/*

    # Mark binaries as executable
    fperms 0755 "/opt/${PN}/${PN}" "/opt/${PN}/lib/${PN}-binary"

    # Wrapper script for /usr/bin
    cat > "${T}/${PN}" <<-EOF
	#!/usr/bin/env bash
	set -euo pipefail
	installdir="/opt/${PN}"
	config_dir="\${XDG_CONFIG_HOME:-\${HOME}/.config}/${PN}"
	state_dir="\${XDG_STATE_HOME:-\${HOME}/.local/state}/${PN}"
	mkdir -p "\${config_dir}" "\${state_dir}"
	cd "\${installdir}"
	exec ./${PN} "\$@"
	EOF
    dobin "${T}/${PN}"

    # Systemd service (optional)
    insinto /usr/lib/systemd/system
    doins "${FILESDIR}/${PN}.service"
}

pkg_postinst() {
    elog "${PN} ${PV} installed."
    elog "Edit ~/.config/${PN}/config.xml with your credentials."
    elog "Enable the service: sudo systemctl enable --now ${PN}"
}
```

## Key Points

- **SRC_URI points at the .deb** — Portage unpacks it via the generic ar+tar fallback as part of `default` in src_unpack
- **Directory structure varies** — some .debs unpack to `opt/<pkg>` (FHS), others to `usr/lib/<pkg>` (Debian layout). Always check with `ar x` + `tar tf data.tar.gz` first
- **Bundled libraries** — the binary likely bundles .so files. Check with `ldd` to identify which system libs are actually needed vs bundled
- **RESTRICT="bindist mirror strip"** — standard for proprietary binary packages
- **LICENSE="all-rights-reserved"** — standard for proprietary
- **Wrapper script** — sets up XDG config/state dirs and cds into /opt/<pkg> so bundled .so files find each other via $ORIGIN/rpath
