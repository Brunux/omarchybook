#!/bin/bash
# Build the kernel packages of the selected device's kernel flavor and publish
# them into the local [platform] bundle (docs/plan.md Phase 1).
#
# Why a package and not `make install`: on this device the kernel lives inside
# the signed depthcharge FIT in the kernel partition, so a kernel update is not
# finished until p1 is rewritten, and that is an ALPM hook's job (boot/). The
# device installs it with `pacman -S linux-omarchy-book`, exactly as the rest of
# the system is installed.
#
# The recipe is ours (kernels/<flavor>: PKGBUILD, version, config.aarch64,
# patches/), unlike the vendored ones, but building it is the same job as any
# other recipe: this wrapper only says why the kernel is a package, and
# scripts/build-package.sh knows how (chroot, makedepends, work tree, stamp,
# signing). Run it through here so that reasoning stays next to the kernel
# rather than being repeated in the recipe.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

log "Device : $DEVICE ($DEVICE_ARCH)"
log "Kernel : $KERNEL_FLAVOR $KERNEL_RELEASE ($KERNEL_ARCH)"

exec "$(dirname "$0")/build-package.sh" "$KERNEL_DIR"
# vim:set ts=8 sts=2 sw=2 et:
