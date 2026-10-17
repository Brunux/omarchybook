#!/bin/bash
# Build a distributable disk image from the built rootfs, without a card.
#
# Usage: make-image.sh [OUTPUT.img] [SIZE_MIB]
#
#   OUTPUT    destination, default $WORK_DIR/<device>.img
#   SIZE_MIB  total size, default $IMAGE_SIZE_MIB, or the size of the rootfs
#             plus a little headroom (see below)
#
# The image carries the same ChromeOS GPT and the same signed kpart as
# scripts/write-sd.sh -- both come from boot/lib-cgpt.sh -- so flashing it is
# plain dd:
#
#   xz -dc google-asurada.img.xz | sudo dd of=/dev/mmcblk1 bs=4M conv=fsync
#
# Two things differ from write-sd.sh, and both are about the file being
# *published*:
#
#   * the size is fixed by argument instead of taken from a device, so the same
#     build can be written to any card that is at least this big;
#   * the copy is sanitized (scripts/lib-dist.sh) and asserted clean, because
#     the build rootfs is a working system that knows more than the image should.
#
# Ported from debian-aarch64 (docs/plan.md 2.5, 4). The differences are this
# port's: the default size is derived from the rootfs because an Arch + Omarchy
# install is ~9 GiB and a fixed 4 GiB image would die mid-copy (the Debian
# original is small enough for a constant), and the sanitize/assert pair grew the
# build-state rules scripts/lib-dist.sh documents.
#
# A card larger than the image keeps the unused space: growing the root partition
# is `cgpt add -i 3 -s <sectors>` plus a resize2fs, documented in the release
# notes. This script does not do it, because it does not know the card.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"
# shellcheck source=lib-dist.sh
. "$(dirname "$0")/lib-dist.sh"

IMG="${1:-$WORK_DIR/$DEVICE.img}"
SIZE_MIB="${2:-${IMAGE_SIZE_MIB:-}}"
KPART_IMG="$WORK_DIR/kpart-image-$DEVICE.img"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" ROOTFS="$ROOTFS" \
		DEVICE="$DEVICE" IMAGE_SIZE_MIB="${IMAGE_SIZE_MIB:-}" \
		BOOT_SIZE_MIB="$BOOT_SIZE_MIB" BOOT_FS="$BOOT_FS" KPART="$KPART" \
		"$(readlink -f "$0")" "$IMG" "$SIZE_MIB"
fi

[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run scripts/build-rootfs.sh first)"
[ -f "$ROOTFS/$KERNEL_IMAGE_REL" ] ||
	die "the rootfs has no /$KERNEL_IMAGE_REL; is it built for $DEVICE?"

# du_mib() rather than `du -B`: the build host's du is BusyBox, which has no -B.
if [ -z "$SIZE_MIB" ]; then
	_used_mib="$(du_mib "$ROOTFS")"
	# 12.5% plus a quarter of a GiB: ext4's own metadata, the reserved blocks
	# and whatever the first boot writes. Rounded up to 256 MiB so the geometry
	# is a round number.
	SIZE_MIB=$(( (_used_mib + _used_mib / 8 + 256 + 255) / 256 * 256 ))
	[ "$SIZE_MIB" -ge 4096 ] || SIZE_MIB=4096
	log "SIZE_MIB not given: $ROOTFS uses ${_used_mib} MiB, building a ${SIZE_MIB} MiB image"
fi
case "$SIZE_MIB" in
	'' | *[!0-9]*) die "SIZE_MIB must be a number of MiB: $SIZE_MIB" ;;
esac

avail_mib="$(df -Pk "$WORK_DIR" | awk 'NR == 2 { print int($4 / 1024) }')"
[ "$avail_mib" -ge $((SIZE_MIB + 512)) ] ||
	die "not enough space in $WORK_DIR for a ${SIZE_MIB} MiB image: ${avail_mib} MiB free
the rootfs plus a build-chroot plus this image is what fills the disk;
reclaim with: rm -rf $BUILD_CHROOT/build $WORK_DIR/rootfs-*"
if [ "$avail_mib" -lt $((SIZE_MIB + SIZE_MIB / 2)) ]; then
	warn "only ${avail_mib} MiB free in $WORK_DIR: make-release.sh also needs to compress this image"
fi

log "Image: $IMG ($SIZE_MIB MiB, device=$DEVICE)"
rm -f "$IMG"
truncate -s "${SIZE_MIB}M" "$IMG"

# Populate through a loop device, so the layout code -- written against a disk
# and its /dev/<disk>p<n> partitions -- is reused unchanged instead of being
# reimplemented with partition offsets. -P makes the kernel scan the new table.
MNT="$WORK_DIR/image-mnt-$DEVICE"
LOOP=""
# shellcheck disable=SC2064
trap 'disk_layout_umount "$MNT" 2>/dev/null || true; [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true' EXIT
LOOP="$(losetup --show -f -P "$IMG")"
log "Loop device: $LOOP"

disk_release "$LOOP"
disk_layout_create "$LOOP"
disk_layout_parts "$LOOP"
disk_layout_mount "$LOOP" "$MNT"

# The maintainer's state is excluded from the copy rather than deleted after it:
# a deleted file is still in the image's free blocks (scripts/lib-dist.sh).
log "Copying the root filesystem"
EXCLUDES="$WORK_DIR/dist-excludes-$DEVICE.txt"
dist_write_excludes "$EXCLUDES"
rsync -aHAX --delete --exclude-from="$EXCLUDES" "$ROOTFS"/ "$MNT"/
disk_layout_fstab "$MNT"
dist_sanitize "$MNT"
dist_assert_clean "$MNT"
dist_report_login_accounts "$MNT"

CMDLINE_EXTRA="root=UUID=$ROOT_UUID rootwait rw"
log "Building the kpart (cmdline: $KERNEL_CMDLINE$CMDLINE_EXTRA)"
"$BOOT_DIR/make-kpart.sh" "$MNT" "$KPART_IMG" "$CMDLINE_EXTRA"
kpart_fits "$KPART_IMG" "$KPART_PART"
kpart_verify "$KPART_IMG"

log "Writing the kpart to $KPART_PART"
dd if="$KPART_IMG" of="$KPART_PART" bs=1M conv=fsync
sync
disk_layout_umount "$MNT"
losetup -d "$LOOP"
LOOP=""
trap - EXIT

# A clean filesystem is not enough: the image is what gets published, free
# blocks included.
dist_assert_no_profile_bytes "$IMG"

log "Done: $IMG ($(file_mib "$IMG") MiB of data, $(du -h "$IMG" | cut -f1) on disk)"
log "Compress and write with: xz -T0 -6 -k $IMG && xz -dc $IMG.xz | sudo dd of=<card> bs=4M conv=fsync"
cgpt show "$IMG" || true
