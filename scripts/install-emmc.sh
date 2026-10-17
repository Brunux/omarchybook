#!/bin/bash
# Install the currently running system onto the internal eMMC (default
# /dev/mmcblk0): the card that has just been tested becomes the machine's disk.
#
# This is the counterpart of pmbootstrap's ChromeOS install path (partition_cgpt
# + write_cgpt_kpart) without pmbootstrap: the same ChromeOS GPT layout, the same
# cgpt flags, the same signed kpart in p1. What differs from pmbootstrap is the
# source of the files -- it copies a rootfs it built in a chroot, this copies the
# system it is running from, i.e. the installation that has already booted.
#
# WARNING: DESTROYS the target disk's contents. Run it from the microSD-booted
# system, with CONFIRM=yes.
#
# Usage: CONFIRM=yes scripts/install-emmc.sh        (DEVICE_BLOCK=/dev/mmcblk0)
#
# Ported from debian-aarch64 (docs/plan.md 2.5, 4). The differences are Arch's:
# the boot chain it invokes is boot/make-kpart.sh, the filesystem it creates is
# ext4 (plan 3.4), and the "after a kernel update" note at the end names this
# port's mechanism (the ALPM hook / omarchy-google-boot kpart-rewrite) instead of
# Debian's install-kernel.sh + install-kpart.sh pair.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"

BLOCK="${DEVICE_BLOCK:-/dev/mmcblk0}"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" ROOTFS="$ROOTFS" \
		DEVICE="$DEVICE" DEVICE_BLOCK="$BLOCK" \
		BOOT_SIZE_MIB="$BOOT_SIZE_MIB" BOOT_FS="$BOOT_FS" KPART="$KPART" \
		"$(readlink -f "$0")" "$@"
fi

[ -b "$BLOCK" ] || die "not a block device: $BLOCK"

# The kernel that is running has to be the one that ends up in the kpart: it is
# the kernel the card has just booted with, so the release is not taken from the
# repository but from the running system, exactly as install-kpart.sh does.
KERNEL_RELEASE="$(uname -r)"
export KERNEL_RELEASE
export KERNEL_IMAGE_REL="boot/vmlinuz-$KERNEL_RELEASE"
export INITRAMFS_REL="boot/initramfs-$KERNEL_RELEASE.img"
[ -d "/lib/modules/$KERNEL_RELEASE" ] || die "no modules for the running kernel $KERNEL_RELEASE"
[ -f "/$KERNEL_IMAGE_REL" ] || die "no /$KERNEL_IMAGE_REL: is this the system build-rootfs.sh built?"
[ -f "/$INITRAMFS_REL" ] || die "no /$INITRAMFS_REL: run mkinitcpio before installing to eMMC"

# Never install onto the disk we are running from: the intended flow is
# card -> eMMC, and this is the check that keeps it that way.
ROOT_SRC="$(findmnt -n -o SOURCE /)"
case "$ROOT_SRC" in
	"$BLOCK" | "$BLOCK"p* | "$BLOCK"[0-9]*) die "already running from $BLOCK; boot from the microSD first" ;;
esac
WORK_SRC="$(findmnt -n -o SOURCE -T "$WORK_DIR" 2>/dev/null || true)"
case "$WORK_SRC" in
	"$BLOCK" | "$BLOCK"p* | "$BLOCK"[0-9]*)
		die "refusing to erase $BLOCK: it carries the build root ($WORK_DIR)"
		;;
esac

log "About to ERASE and install $DEVICE on $BLOCK"
log "  running root  : $ROOT_SRC (kernel $KERNEL_RELEASE)"
log "  build root    : $WORK_DIR"
lsblk "$BLOCK"
[ "${CONFIRM:-}" = "yes" ] || die "refusing to continue without CONFIRM=yes"

log "Creating the ChromeOS GPT on $BLOCK (kernel $((KPART_SIZE_SECTORS * 512 / 1024 / 1024)) MiB, boot ${BOOT_SIZE_MIB} MiB)"
disk_release "$BLOCK"
disk_layout_create "$BLOCK"
disk_layout_parts "$BLOCK"

MNT="$WORK_DIR/emmc-mnt-$DEVICE"
disk_layout_mount "$BLOCK" "$MNT"

# Copy the running system. /boot ends up on the boot partition because it is
# mounted inside the target ($MNT/boot), and everything volatile is left out so
# the eMMC does not inherit the card's journal, caches, temporary files or the
# build tree. $MNT is excluded by name as well: it lives under $WORK_DIR, which
# is usually on this same filesystem.
log "Copying the running system to $MNT"
rsync -aHAX --delete \
	--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
	--exclude=/mnt --exclude=/media --exclude="$MNT" --exclude="$WORK_DIR" \
	--exclude=/tmp/ --exclude=/var/tmp/ \
	--exclude=/var/cache/ --exclude=/var/log/journal/ \
	/ "$MNT"/
disk_layout_fstab "$MNT"

log "Building the kpart for the eMMC root (root=UUID=$ROOT_UUID, kernel $KERNEL_RELEASE)"
"$BOOT_DIR/make-kpart.sh" "$MNT" "$KPART.emmc" "root=UUID=$ROOT_UUID rootwait rw"
kpart_fits "$KPART.emmc" "$KPART_PART"
kpart_verify "$KPART.emmc"

log "Writing the kpart to $KPART_PART"
dd if="$KPART.emmc" of="$KPART_PART" bs=1M conv=fsync
sync
disk_layout_umount "$MNT"

log "Done. Reboot and remove the microSD to boot from the eMMC."
log "  After a kernel update on the eMMC system, p1 is rewritten by the boot"
log "  package's ALPM hook (or: omarchy-google-boot kpart-rewrite)."
cgpt show "$BLOCK"
