# Kernel Source Makefile After Build

On Gentoo, after building and installing a kernel, the `/usr/src/linux-<ver>/` tree often has its Makefile stripped (it's not needed post-install for boot — only for building modules or tools like `chrome-sandbox`).

## Checking

```bash
# Find the running kernel version
uname -r

# Check the symlink target and Makefile
readlink /usr/src/linux
ls /usr/src/linux/Makefile          # may not exist
ls /usr/src/linux-$(uname -r)/Makefile  # same

# List all kernel trees on disk
ls /usr/src/
```

## Does It Matter?

- **For boot:** No. `/boot/vmlinuz-*` and `/boot/initramfs-*` are what matters.
- **For tools like Chrome / nvidia-drivers:** Yes — `chrome-sandbox` and GPU driver builds check the Makefile to find the kernel version and verify config options are set. If it's missing, you'll get a warning during emerge but the package still installs (just without sandbox/suid checking).
- **For building external kernel modules:** Yes — you need the full source. If Makefile is missing, extract it from the kernel source tarball or rebuild without `make clean` that removes it.

## Fix (if needed)

If a tool needs the Makefile, copy it from the kernel source tarball or from another kernel tree on disk that still has it:

```bash
# If another kernel tree on disk has the Makefile
cp /usr/src/linux-<other-version>/Makefile /usr/src/linux-$(uname -r)/
```
