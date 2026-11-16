# Kernel Sources Preservation After Depclean

## Problem
`emerge --depclean` may remove `sys-kernel/gentoo-sources` if the package is not in `@world` and no other package requires it. If the removed version is the only available kernel source tree, the `/usr/src/linux` symlink becomes dangling.

## Detection
Before depclean:
```bash
eselect kernel list
qlist -I sys-kernel/gentoo-sources
```
After depclean, verify:
```bash
ls -la /usr/src/linux
```

## Prevention
Add `sys-kernel/gentoo-sources` to `@world` or protect the package:
```bash
sudo emerge --noreplace sys-kernel/gentoo-sources
```

## Recovery
If sources were removed and no valid sources remain:
```bash
sudo emerge --oneshot sys-kernel/gentoo-sources-<version>
sudo eselect kernel set linux-<version>-gentoo
```
