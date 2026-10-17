#!/bin/bash
# Check the tools this repository needs on the machine where it is run.
#
# This is the Arch port of the sibling project's 00-deps.sh, and it is a *check*
# rather than an installer on purpose: the sibling installs a fixed package list
# with apk because its build host is Alpine, while this port's build host is a
# ChromeOS machine running whatever the maintainer runs (here: the sibling's own
# Nura), and no single package manager covers the two halves it needs.
#
# The two halves are:
#
#   * the packaging half (Phase 1-3): an Arch chroot with pacman/makepkg/repo-add.
#     scripts/build-omarchy.sh creates and fills it; nothing here installs into
#     it, so a missing one is reported as "run build-omarchy.sh once".
#   * the device half (Phase 5-6): the ChromeOS tools this port drives -- cgpt,
#     futility, depthchargectl -- plus the filesystem tools the layout needs. On
#     this hardware the build host *is* a ChromeOS device, so they are all one
#     install away; on a generic host they would come from vboot-utils,
#     depthcharge-tools and e2fsprogs.
#
# Exit status is 0 only when every required tool is there.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

missing=""
optional_missing=""
_checks=0

# need <tool> <why> <package>
need() {
	_checks=$((_checks + 1))
	command -v "$1" >/dev/null 2>&1 && return 0
	missing="$missing
  $1 -- $2 (package: $3)"
}

# want <tool> <why> <package>: nice to have, the scripts carry on without it.
want() {
	_checks=$((_checks + 1))
	command -v "$1" >/dev/null 2>&1 && return 0
	optional_missing="$optional_missing
  $1 -- $2 (package: $3)"
}

# --- the ChromeOS boot chain (Phase 5, Phase 6) -----------------------------
need cgpt "read and write the ChromeOS GPT (boot/lib-cgpt.sh)" vboot-utils
need futility "verify the signed FIT a kpart is (boot/lib-cgpt.sh)" vboot-utils
need depthchargectl "build the kpart (boot/make-kpart.sh)" depthcharge-tools

# --- the layout and the filesystems it creates ------------------------------
need parted "create the protective MBR and GPT table" parted
need losetup "make-image.sh and restore-system.sh work on an image through one" util-linux
need partx "re-read the partition table (avoiding BLKRRPART's EBUSY)" util-linux
need blkid "read filesystem UUIDs" util-linux
need findmnt "resolve what the running root is on" util-linux
need mountpoint "check before mounting and unmounting" util-linux
need blockdev "read the disk size in sectors" util-linux
need wipefs "clear stale signatures before cgpt" util-linux
need mkfs.ext4 "create p3, the root filesystem (plan 3.4)" e2fsprogs
need mkfs.ext2 "create p2 on a build that sets BOOT_FS=ext2" e2fsprogs
need rsync "copy the rootfs onto a disk, an image or an eMMC" rsync

# --- the artifacts ----------------------------------------------------------
need xz "compress the released image" xz
need zstd "compress the released rootfs tarball" zstd
need gzip "backup-system.sh writes tars macOS can read" gzip
need sha256sum "SHA256SUMS, and checking a backup before restoring it" coreutils
need cmp "prove the GPT written back matches the backup" diffutils
want pigz "much faster backup tars" pigz
want sgdisk "a portable GPT backup beside the raw dumps" gptfdisk
want git "record the commit a release was built from" git

# --- GNU tar: the backups and the tarball depend on its options -------------
# The help text is captured first: `tar --help | grep -q` trips the pipefail trap
# this repository documents (docs/recon.md 12) -- grep exits on the match, tar
# gets SIGPIPE, and the pipeline reports 141 as if the option were missing.
if command -v tar >/dev/null 2>&1; then
	_tar_help="$(tar --help 2>/dev/null || true)"
	for _o in --acls --xattrs; do
		_checks=$((_checks + 1))
		case "$_tar_help" in
		*"$_o"*) ;;
		*)
			missing="$missing
  tar $_o -- the backups and the released tarball use it (a GNU tar is required, not BusyBox')"
			;;
		esac
	done
else
	missing="$missing
  tar -- pack the rootfs and back it up (package: tar)"
fi

# --- the vendored vboot keys (boot/devkeys) ---------------------------------
for _k in kernel.keyblock kernel_subkey.vbpubk kernel_data_key.vbprivk; do
	_checks=$((_checks + 1))
	[ -f "$DEPTHCHARGE_KEYDIR/$_k" ] ||
		missing="$missing
  $DEPTHCHARGE_KEYDIR/$_k -- sign the kpart (ALARM's vboot-utils ships no keys; see boot/devkeys/README)"
done

# --- the packaging half -----------------------------------------------------
_checks=$((_checks + 1))
if [ -d "$BUILD_CHROOT" ]; then
	for _t in pacman makepkg repo-add; do
		_checks=$((_checks + 1))
		[ -x "$BUILD_CHROOT/usr/bin/$_t" ] ||
			missing="$missing
  $_t -- the packaging half of the build (in $BUILD_CHROOT, the chroot build-omarchy.sh makes)"
	done
else
	missing="$missing
  $BUILD_CHROOT -- where packages are built (run scripts/build-omarchy.sh once, then build-package.sh)"
fi

log "Checked $_checks things"
if [ -n "$optional_missing" ]; then
	warn "optional, missing:"
	printf '%s\n' "$optional_missing" | sed 's/^/  /'
fi
if [ -n "$missing" ]; then
	printf '%s\n' "required, missing:" >&2
	printf '%s\n' "$missing" | sed 's/^/  /' >&2
	die "install the ones above (the package names in parentheses are Arch's; the [platform] bundle's own do not need any host install)"
fi
log "All required tools are present"
