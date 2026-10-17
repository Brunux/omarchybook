#!/bin/bash
# Partition and populate a microSD/USB device so it boots via depthcharge (Ctrl+U).
#
# The layout is the one boot/lib-cgpt.sh creates (the single copy of it):
#   p1  kernel  128 MiB  signed FIT kpart
#   p2  boot    512 MiB  the kernel, the initramfs and the DTBs
#   p3  root    the rest  the Arch Linux ARM + Omarchy root filesystem
#
# Usage: write-sd.sh [DEVICE]        (default: /dev/mmcblk1)
#
# Ported from debian-aarch64 (docs/plan.md 2.5, 4): the layout, the cgpt flags
# and the order (parted's table first, then cgpt on top of it) are unchanged. On
# this project the GPT helpers live in boot/ because the device's boot package
# ships the same file (boot/lib-cgpt.sh is canonical and consumed from here), the
# kpart is built by boot/make-kpart.sh for the same reason, and the two
# partitions that are not p1 are ext4 (plan 3.4).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"

BLOCK="${1:-/dev/mmcblk1}"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" ROOTFS="$ROOTFS" \
		DEVICE="$DEVICE" BOOT_SIZE_MIB="$BOOT_SIZE_MIB" BOOT_FS="$BOOT_FS" KPART="$KPART" \
		"$(readlink -f "$0")" "${1:-}"
fi

[ -b "$BLOCK" ] || die "not a block device: $BLOCK"
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run scripts/build-rootfs.sh first)"
[ -f "$ROOTFS/$KERNEL_IMAGE_REL" ] ||
	die "the rootfs has no /$KERNEL_IMAGE_REL; is it built for $DEVICE?"

# Safety, and the reason this script exists as a separate thing from
# install-emmc.sh: the card writer must never touch the machine it runs on.
#   * mmcblk0 is the internal eMMC -- on this hardware the build host is the
#     device itself, so a typo here would erase the maintainer's system.
#   * anything the running root or the build root lives on is equally fatal:
#     the build tree ($BUILD_ROOT, GiB of it) is usually on the internal disk,
#     but it can perfectly well be on an external SSD that also looks like a
#     card reader.
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
WORK_SRC="$(findmnt -n -o SOURCE -T "$WORK_DIR" 2>/dev/null || true)"
case "$BLOCK" in
	*/mmcblk0 | */mmcblk0p* | */zram*) die "refusing to write to $BLOCK (internal eMMC or zram)" ;;
esac
case "$ROOT_SRC" in
	"$BLOCK" | "$BLOCK"p* | "$BLOCK"[0-9]*) die "refusing to write to the running root device: $BLOCK" ;;
esac
case "$WORK_SRC" in
	"$BLOCK" | "$BLOCK"p* | "$BLOCK"[0-9]*)
		die "refusing to write to $BLOCK: it carries the build root ($WORK_DIR)"
		;;
esac

log "Device: $DEVICE -> $BLOCK ($(blockdev --getsize64 "$BLOCK") bytes)"
disk_release "$BLOCK"

log "Creating the ChromeOS GPT on $BLOCK (kernel $((KPART_SIZE_SECTORS * 512 / 1024 / 1024)) MiB, boot ${BOOT_SIZE_MIB} MiB)"
disk_layout_create "$BLOCK"
disk_layout_parts "$BLOCK"

MNT="$WORK_DIR/sd-mnt-$DEVICE"
disk_layout_mount "$BLOCK" "$MNT"

# Regenerable or build-only, and both are big: the persistent pacman cache
# (scripts/lib.sh: $PACMAN_CACHE, bind-mounted into the rootfs while it is built)
# and the build-time [platform] bundle. A card does not need either, and the
# bundle is unreachable once Omarchy's own pacman.conf replaces the build one.
log "Copying the root filesystem"
rsync -aHAX --delete \
	--exclude=/var/cache/pacman/pkg/ --exclude=/packages/ \
	--exclude=/tmp/ --exclude=/var/tmp/ \
	"$ROOTFS"/ "$MNT"/
disk_layout_fstab "$MNT"

log "Building the kpart (root=UUID=$ROOT_UUID)"
"$BOOT_DIR/make-kpart.sh" "$MNT" "$KPART" "root=UUID=$ROOT_UUID rootwait rw"
kpart_fits "$KPART" "$KPART_PART"
kpart_verify "$KPART"

log "Writing the kpart to $KPART_PART"
dd if="$KPART" of="$KPART_PART" bs=1M conv=fsync
sync
disk_layout_umount "$MNT"

log "Done. Remove $BLOCK and boot with Ctrl+U."
cgpt show "$BLOCK" || true
