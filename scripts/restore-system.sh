#!/bin/bash
# Restore a backup written by backup-system.sh onto a disk, so a machine whose
# internal storage was overwritten can be put back the way it was.
#
# Usage:
#   sudo scripts/restore-system.sh <backup-directory> [target-disk]
#
#   CONFIRM=yes sudo scripts/restore-system.sh /mnt/backup/asurada-backup-2026-10-16
#   TARGET=/dev/mmcblk0 DEEP=yes sudo scripts/restore-system.sh /mnt/backup/...
#
# It must run as root and from a system that does NOT live on the target disk:
# the intended way is the microSD-booted system of this repository, with the
# backup on a mounted removable disk. Unlike the other scripts this one does not
# re-exec itself through sudo -- a restore rewrites a disk, and privilege
# escalation should never be silent (need_root() in scripts/lib.sh says the same).
#
# What it does, in order:
#   1. reads the backup: the original disk size from the recorded partition
#      table, the filesystem UUIDs from the /etc/fstab inside the archive (the
#      system's own record of what it needs, so the restore is consistent by
#      construction);
#   2. checks SHA256SUMS, so a corrupt backup stops before anything is written;
#   3. puts the partition table back byte for byte from the raw GPT dumps -- this
#      is why the disk must be the size the backup came from, which is the case
#      for the machine it was taken from;
#   4. writes the kernel partition (p1) with the backed-up signed FIT, after
#      checking it fits and that futility still accepts it;
#   5. creates p2 and p3 with the *original* UUIDs, so the restored system boots
#      with its own fstab and kernel command line without regenerating either;
#   6. unpacks the two tars with owners, permissions, ACLs and xattrs.
#
# Nothing here assumes THIS repository's layout: the table, the labels and the
# UUIDs come from the backup. boot/lib-cgpt.sh is used only for what it does
# well: releasing the disk and resolving/verifying the partitions.
#
# Environment:
#   TARGET       target whole disk (default /dev/mmcblk0); also the 2nd argument
#   ROOT_UUID    override the root filesystem UUID from the archived fstab
#   BOOT_UUID    override the /boot filesystem UUID from the archived fstab
#   CONFIRM=yes  required; there is no interactive prompt
#   VERIFY=no    skip the SHA256SUMS check (not recommended)
#   DEEP=yes     after restoring, compare the filesystems against the archives
#                with `tar -d` (reads both tars and the new filesystems again)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"

BACKUP="${1:-}"
TARGET="${2:-${TARGET:-/dev/mmcblk0}}"

[ -n "$BACKUP" ] || die "usage: restore-system.sh <backup-directory> [target-disk]"
[ -d "$BACKUP" ] || die "backup is not a directory: $BACKUP"
need_root

# ---------------------------------------------------------------------------
# What the backup holds
# ---------------------------------------------------------------------------
KPART_IMG=""
for _f in "$BACKUP"/*-kernel-partition.img; do
	[ -f "$_f" ] || continue
	KPART_IMG="$_f"
	break
done
[ -n "$KPART_IMG" ] ||
	die "no *-kernel-partition.img in $BACKUP; is that a backup-system.sh backup?"
HOST="${KPART_IMG##*/}"
HOST="${HOST%-kernel-partition.img}"

ROOTFS_TAR="$BACKUP/$HOST-rootfs.tar.gz"
BOOT_TAR="$BACKUP/$HOST-boot.tar.gz"
GPT_PRIMARY="$BACKUP/$HOST-gpt-primary.img"
GPT_BACKUP="$BACKUP/$HOST-gpt-backup.img"
PARTITIONS_TXT="$BACKUP/$HOST-partitions.txt"

for _f in "$ROOTFS_TAR" "$BOOT_TAR" "$GPT_PRIMARY" "$GPT_BACKUP"; do
	[ -f "$_f" ] || die "missing from the backup: $_f"
done

# The original geometry. The raw GPT dumps can only be written back on a disk of
# the same size, so the backup has to record it: the start sector of the GPT's
# own backup copy, plus one.
ORIG_TOTAL=""
[ -f "$PARTITIONS_TXT" ] &&
	ORIG_TOTAL="$(awk '/Sec GPT header/ { print $1 + 1; exit }' "$PARTITIONS_TXT")"
if [ -z "$ORIG_TOTAL" ]; then
	# Fallback: AlternateLBA in the primary header (the header sits at LBA 1,
	# the field at offset 32 in it) is the last usable LBA of the source disk.
	_alt="$(od -An -tu8 -j 544 -N 8 "$GPT_PRIMARY" 2>/dev/null | tr -d ' ')"
	[ -n "$_alt" ] && ORIG_TOTAL=$((_alt + 1)) || ORIG_TOTAL=0
fi
case "$ORIG_TOTAL" in
	'' | *[!0-9]*) die "cannot tell how big the backed-up disk was (no usable '$HOST-partitions.txt' and no readable GPT header)" ;;
esac
[ "$ORIG_TOTAL" -gt 0 ] || die "the backed-up disk size came out as 0 sectors"

# The UUIDs the restored filesystems must carry. They are read out of the fstab
# inside the archive rather than from a transcript of the old machine, so they
# are exactly the ones the restored system asks for.
ROOT_UUID="${ROOT_UUID:-}"
BOOT_UUID="${BOOT_UUID:-}"
SWAP_UUID=""
if [ -z "$ROOT_UUID" ] || [ -z "$BOOT_UUID" ]; then
	log "Reading the filesystem UUIDs from the /etc/fstab inside $HOST-rootfs.tar.gz"
	log "  (that scans the archive up to that file; ROOT_UUID/BOOT_UUID skip this step)"
	_ftmp="$(mktemp)"
	trap 'rm -f "$_ftmp"' EXIT
	tar -xzOf "$ROOTFS_TAR" ./etc/fstab >"$_ftmp" 2>/dev/null ||
		die "cannot read ./etc/fstab out of $ROOTFS_TAR"
	[ -n "$ROOT_UUID" ] ||
		ROOT_UUID="$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' "$_ftmp")"
	[ -n "$BOOT_UUID" ] ||
		BOOT_UUID="$(awk '$2 == "/boot" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' "$_ftmp")"
	SWAP_UUID="$(awk '$3 == "swap" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' "$_ftmp")"
fi
[ -n "$ROOT_UUID" ] || die "the archived /etc/fstab has no UUID= entry for / (pass ROOT_UUID=...)"
[ -n "$BOOT_UUID" ] || die "the archived /etc/fstab has no UUID= entry for /boot (pass BOOT_UUID=...)"

# ---------------------------------------------------------------------------
# The target
# ---------------------------------------------------------------------------
[ -b "$TARGET" ] || die "not a block device: $TARGET"
case "$(lsblk -ndo TYPE "$TARGET" 2>/dev/null || true)" in
	disk | loop) : ;;
	*) die "target must be a whole disk, not a partition: $TARGET" ;;
esac

# The check that matters: never restore onto the disk we are running from.
ROOT_SRC="$(findmnt -n -o SOURCE /)"
case "$ROOT_SRC" in
	"$TARGET" | "$TARGET"p* | "$TARGET"[0-9]*)
		die "this system is running from $TARGET ($ROOT_SRC); boot from microSD and run the restore there"
		;;
esac

# Nor onto the disk that holds the backup itself. `|| true` on the lsblk: with
# pipefail a head that stops the pipe early is 141, not "no disk" (recon 12).
BACKUP_SRC="$(findmnt -n -o SOURCE -T "$BACKUP" 2>/dev/null || true)"
BACKUP_DISK="$(lsblk -no PKNAME "$BACKUP_SRC" 2>/dev/null | head -1 || true)"
if [ -n "$BACKUP_DISK" ] && [ "$BACKUP_DISK" = "$(basename "$TARGET")" ]; then
	die "the backup lives on $BACKUP_DISK, the disk to be restored; move the backup to another disk"
fi

TARGET_TOTAL="$(blockdev --getsz "$TARGET")"
[ "$TARGET_TOTAL" -eq "$ORIG_TOTAL" ] ||
	die "$TARGET has $TARGET_TOTAL sectors, the backup came from a disk with $ORIG_TOTAL: the raw GPT dumps only fit the original size (on a different disk, use 'sgdisk --load-backup=$HOST-gpt.bin' or recreate the layout with boot/lib-cgpt.sh)"

log "About to ERASE $TARGET and restore the backup of '$HOST'"
log "  backup          : $BACKUP"
log "  disk            : $TARGET, $TARGET_TOTAL sectors ($((TARGET_TOTAL / 2 / 1024)) MiB)"
log "  running system  : $ROOT_SRC (the restore is refused if that is the target)"
log "  kernel partition: $HOST-kernel-partition.img"
log "  filesystems     : p2 $BOOT_FS pmOS_boot UUID $BOOT_UUID, p3 ext4 pmOS_root UUID $ROOT_UUID"
lsblk "$TARGET"

if [ -f "$BACKUP/SHA256SUMS" ]; then
	if [ "${VERIFY:-yes}" = "no" ]; then
		warn "VERIFY=no: not checking the backup against its SHA256SUMS"
	else
		log "Verifying the backup against SHA256SUMS (this reads the whole backup)"
		# No --quiet: a host running busybox' sha256sum has no such option, and
		# this script can be run from a recovery system that is not Arch.
		set +e
		_sums="$(cd "$BACKUP" && sha256sum -c SHA256SUMS 2>&1)"
		_rc="$?"
		set -e
		if [ "$_rc" -ne 0 ]; then
			printf '%s\n' "$_sums" | sed 's/^/  /'
			die "the backup does not match its SHA256SUMS; refusing to restore it"
		fi
		log "  checksums OK ($(printf '%s\n' "$_sums" | grep -c ': OK$' || true) files)"
	fi
else
	warn "no SHA256SUMS in $BACKUP: cannot check the backup before writing it back"
fi

[ "${CONFIRM:-}" = "yes" ] || die "refusing to continue without CONFIRM=yes"

# ---------------------------------------------------------------------------
# 1. The partition table, exactly as it was
# ---------------------------------------------------------------------------
log "Writing the original GPT to $TARGET"
disk_release "$TARGET"
dd if="$GPT_PRIMARY" of="$TARGET" bs=512 count=34 conv=fsync 2>/dev/null
dd if="$GPT_BACKUP" of="$TARGET" bs=512 seek=$((TARGET_TOTAL - 33)) count=33 conv=fsync 2>/dev/null
partx -d "$TARGET" 2>/dev/null || true
partx -a "$TARGET" 2>/dev/null || blockdev --rereadpt "$TARGET" 2>/dev/null || true
command -v udevadm >/dev/null && udevadm settle || sleep 2

# Both areas are a few sectors: exactness is cheap to prove here.
dd if="$TARGET" bs=512 count=34 2>/dev/null | cmp -s - "$GPT_PRIMARY" ||
	die "the primary GPT written to $TARGET does not match the backup"
dd if="$TARGET" bs=512 skip=$((TARGET_TOTAL - 33)) count=33 2>/dev/null |
	cmp -s - "$GPT_BACKUP" ||
	die "the backup GPT written to $TARGET does not match the backup"
log "  GPT matches the backup, primary and backup copy"

disk_layout_parts "$TARGET"
log "  p1 $KPART_PART, p2 $BOOT_PART, p3 $ROOT_PART"

# ---------------------------------------------------------------------------
# 2. The kernel partition: the signed FIT depthcharge loads
# ---------------------------------------------------------------------------
log "Writing $KPART_IMG to $KPART_PART"
kpart_fits "$KPART_IMG" "$KPART_PART"
kpart_verify "$KPART_IMG"
dd if="$KPART_IMG" of="$KPART_PART" bs=1M conv=fsync 2>/dev/null
sync

# ---------------------------------------------------------------------------
# 3. The filesystems, with the UUIDs the restored system expects
# ---------------------------------------------------------------------------
log "Creating $BOOT_PART ($BOOT_FS, label pmOS_boot, UUID $BOOT_UUID)"
"mkfs.$BOOT_FS" -F -L pmOS_boot -U "$BOOT_UUID" "$BOOT_PART" >/dev/null
log "Creating $ROOT_PART (ext4, label pmOS_root, UUID $ROOT_UUID)"
mkfs.ext4 -F -L pmOS_root -U "$ROOT_UUID" "$ROOT_PART" >/dev/null

for _p in "$BOOT_PART" "$ROOT_PART"; do
	_re="$(blkid -s UUID -o value "$_p" 2>/dev/null || true)"
	log "  $_p UUID: ${_re:-?}"
done
[ "$(blkid -s UUID -o value "$BOOT_PART")" = "$BOOT_UUID" ] ||
	die "$BOOT_PART did not take UUID $BOOT_UUID"
[ "$(blkid -s UUID -o value "$ROOT_PART")" = "$ROOT_UUID" ] ||
	die "$ROOT_PART did not take UUID $ROOT_UUID"

MNT="$WORK_DIR/restore-mnt-$DEVICE"
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"

log "Unpacking the root filesystem (this is the slow part)"
tar -xpf "$ROOTFS_TAR" -C "$MNT" --numeric-owner --acls --xattrs \
	--xattrs-include='*' --warning=no-unknown-keyword
sync

mkdir -p "$MNT/boot"
mount "$BOOT_PART" "$MNT/boot"
log "Unpacking /boot"
tar -xpf "$BOOT_TAR" -C "$MNT/boot" --numeric-owner --acls --xattrs \
	--xattrs-include='*' --warning=no-unknown-keyword
sync

# ---------------------------------------------------------------------------
# 4. What was restored, and what was restored into it
# ---------------------------------------------------------------------------
[ -e "$MNT/etc/fstab" ] || die "$MNT/etc/fstab is missing: the root archive did not unpack"
for _u in "$ROOT_UUID" "$BOOT_UUID"; do
	grep -q "UUID=$_u" "$MNT/etc/fstab" ||
		die "the restored /etc/fstab does not mention UUID=$_u"
done
log "  /etc/fstab of the restored system mentions both UUIDs"

if [ -n "$SWAP_UUID" ]; then
	# The archived fstab may name a swap partition that no partition carries:
	# that machine swapped on zram, which the initramfs sets up. Writing the
	# entry back reproduces the original exactly, so this is a note.
	if ! blkid -U "$SWAP_UUID" >/dev/null 2>&1; then
		warn "the archived /etc/fstab names swap UUID $SWAP_UUID, which no partition carries (the original was the same: swap came from zram)"
	fi
fi

log "Kernel partition after the restore"
kpart_verify "$KPART_PART"

if [ "${DEEP:-}" = "yes" ]; then
	log "Comparing the restored filesystems against the archives (tar -d)"
	for _pair in "$ROOTFS_TAR:$MNT" "$BOOT_TAR:$MNT/boot"; do
		_tar="${_pair%%:*}"
		_dir="${_pair##*:}"
		# No pipeline: with pipefail a `head` closing the pipe early is what the
		# caller would see, not tar's status (the pitfall documented in
		# docs/recon.md 12).
		set +e
		_out="$(tar -dpf "$_tar" -C "$_dir" --numeric-owner --acls --xattrs \
			--xattrs-include='*' --warning=no-unknown-keyword 2>&1)"
		_rc="$?"
		set -e
		printf '%s\n' "$_out" | sed -n '1,20p' | sed 's/^/  /'
		[ "$_rc" -eq 0 ] ||
			die "tar -d disagrees with the restored filesystem: $_tar (exit $_rc)"
	done
	log "  archives and filesystems agree"
fi

sync
disk_layout_umount "$MNT"

log "Restored '$HOST' onto $TARGET"
cgpt show "$TARGET"
log "  firmware next steps: shut down, remove the microSD, power on"
log "  the eMMC is what depthcharge boots by default; the card needs Ctrl+U again"
