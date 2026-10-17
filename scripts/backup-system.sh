#!/bin/bash
# Back up the running installation into a directory, so it can be restored from
# files instead of depending on a disk image.
#
# Usage: backup-system.sh <destination-directory>
#
# What is written there:
#
#   <host>-kernel-partition.img  the ChromeOS kernel partition the system booted
#                                from: the signed FIT depthcharge loads. Resolved
#                                from the kern_guid in /proc/cmdline, so it cannot
#                                be the wrong partition (the same trick
#                                boot/install-kpart.sh uses).
#   <host>-gpt-primary.img       the partition table: the protective MBR, the GPT
#   <host>-gpt-backup.img        header and entry array at the start of the disk,
#                                and the GPT's own backup copy at the end. Plus
#                                <host>-gpt.bin (a portable sgdisk backup) when
#                                sgdisk is installed, and <host>-partitions.txt,
#                                a readable `cgpt show` / `lsblk` transcript.
#   <host>-boot.tar.gz           /boot, as mounted.
#   <host>-rootfs.tar.gz         the root filesystem, without /boot.
#   README.md                    what the files are and how to restore them.
#   SHA256SUMS                   hashes of everything above.
#
# The destination is usually a removable disk formatted with exFAT, which both
# macOS and Linux read -- but exFAT cannot store a Linux root filesystem (owners,
# permissions, symlinks, capabilities), so the filesystems travel as tars, with
# --numeric-owner/--acls/--xattrs and the numeric ids preserved. The two raw files
# are small and are what makes a restore exact.
#
# Regenerable state is left out (caches, package downloads, build directories,
# logs): everything in EXCLUDES is either downloaded again or recreated by the
# system itself. The backup keeps what carries decisions: configuration, sources,
# data.
#
# Ported from debian-aarch64 (docs/plan.md 2.5, 4). Ported as logic, not as text:
# the kernel-update note in the README names this port's mechanism (the boot
# package's ALPM hook / omarchy-google-boot kpart-rewrite) and the exclusion list
# is Arch's paths, not Debian's.
#
# sgdisk (Arch: gptfdisk) is optional but without it the GPT is only recorded as
# a transcript instead of a restorable backup; pigz makes the tars much faster.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"

DEST="${1:-}"
[ -n "$DEST" ] || die "usage: backup-system.sh <destination-directory>"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n "$(readlink -f "$0")" "$DEST"
fi

# Not from a chroot. Nothing here writes to the machine, so this is not about
# safety but about the backup being right: from a chroot /proc/cmdline is the
# host's, so the kernel partition and the partition table recorded below belong
# to the host while the tars belong to the chroot -- a backup whose p1 does not
# match its root filesystem. The Debian original has no such guard; this port
# adds it because the guard it inherited was broken (docs/recon.md 12).
require_real_root

[ -d "$DEST" ] || die "destination is not a directory: $DEST"
DEST_SRC="$(findmnt -n -o SOURCE -T "$DEST" 2>/dev/null || true)"
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[ -n "$DEST_SRC" ] || die "destination is not on a mounted filesystem: $DEST"
[ "$DEST_SRC" != "$ROOT_SRC" ] ||
	die "refusing to write the backup onto the filesystem it is backing up ($DEST is on $ROOT_SRC)"

# Regenerable or per-user state. Anchored at the transfer root.
EXCLUDES='
./home/*/.cache
./home/*/.local/share/Trash
./home/*/.thumbnails
./tmp/*
./var/cache/*
./var/tmp/*
./var/log/journal
./var/log/private/*
./lost+found
'

HOST="$(hostname)"
KERN_GUID="$(sed -n 's/.*kern_guid=\([^ ]*\).*/\1/p' /proc/cmdline)"
KPART_PART=""
[ -n "$KERN_GUID" ] && KPART_PART="$(findfs "PARTUUID=$KERN_GUID" 2>/dev/null || true)"
ROOT_BLK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC" 2>/dev/null || true)"

log "Backup of $HOST -> $DEST ($DEST_SRC)"
log "  kernel partition: ${KPART_PART:-not found (no kern_guid in /proc/cmdline)}"
log "  root device     : $ROOT_SRC (UUID ${ROOT_UUID:-?}, disk ${ROOT_BLK:-?})"
log "  excluded        :$(printf '%s\n' "$EXCLUDES" | sed '/^$/d;s|^\./| |' | tr -d '\n')"
[ -z "${BACKUP_EXCLUDES:-}" ] || log "  plus BACKUP_EXCLUDES: $BACKUP_EXCLUDES"

# gzip is what macOS' own tar reads without extra tools, which is the point of an
# exFAT destination; pigz keeps it from being slow.
COMPRESS="gzip"
command -v pigz >/dev/null && COMPRESS="pigz"

EXCLFILE="$WORK_DIR/backup-excludes.txt"
printf '%s\n' "$EXCLUDES" >"$EXCLFILE"
[ -z "${BACKUP_EXCLUDES:-}" ] || printf '%s\n' "$BACKUP_EXCLUDES" >>"$EXCLFILE"

# A live filesystem changes while tar reads it: that is a warning (exit 1), not a
# failure. Anything worse (unreadable file, I/O error) does stop the backup.
archive() {
	_name="$1" _dir="$2"
	log "Archiving $_dir -> $_name (this is the slow part)"
	set +e
	tar --one-file-system --numeric-owner --acls --xattrs --xattrs-include='*' \
		--exclude-from="$EXCLFILE" --warning=no-file-changed \
		-cpf - -C "$_dir" . | "$COMPRESS" >"$DEST/$_name"
	_rc="${PIPESTATUS[0]}"
	set -e
	case "$_rc" in
	0) : ;;
	1) warn "$_name: a file changed while it was being read (normal on a live system)" ;;
	*) die "tar failed on $_dir (exit $_rc)" ;;
	esac
}

# /boot first (small, so a failure shows up quickly), then the root filesystem.
# --one-file-system keeps /boot out of the second archive: this repository's
# layout has it on its own partition (boot/lib-cgpt.sh).
archive "$HOST-boot.tar.gz" /boot
archive "$HOST-rootfs.tar.gz" /

if [ -n "$KPART_PART" ]; then
	log "Archiving the kernel partition ($KPART_PART)"
	dd if="$KPART_PART" of="$DEST/$HOST-kernel-partition.img" bs=1M conv=fsync 2>/dev/null
fi

if [ -n "$ROOT_BLK" ]; then
	log "Recording the partition table of /dev/$ROOT_BLK"
	# The GPT areas themselves, so the table can be put back exactly with dd: the
	# protective MBR, the header and the entry array at the start, the backup copy
	# at the end. Restoring needs the same disk size, which is the case when the
	# backup is of the machine it would be restored to. sgdisk writes a portable
	# backup as well when it is installed.
	_gpt_total="$(blockdev --getsz "/dev/$ROOT_BLK")"
	dd if="/dev/$ROOT_BLK" of="$DEST/$HOST-gpt-primary.img" bs=512 count=34 2>/dev/null
	dd if="/dev/$ROOT_BLK" of="$DEST/$HOST-gpt-backup.img" bs=512 \
		skip=$((_gpt_total - 33)) count=33 2>/dev/null
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk --backup="$DEST/$HOST-gpt.bin" "/dev/$ROOT_BLK" >/dev/null
	else
		warn "sgdisk not installed (gptfdisk): only the raw GPT dumps, no portable backup"
	fi
	{
		printf '# %s\n\n' "/dev/$ROOT_BLK"
		cgpt show "/dev/$ROOT_BLK" 2>/dev/null || true
		printf '\n'
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,UUID "/dev/$ROOT_BLK" 2>/dev/null || true
	} >"$DEST/$HOST-partitions.txt"
fi

cp "$EXCLFILE" "$DEST/.backup-excludes.txt"
rm -f "$EXCLFILE"

# A backup nobody can restore is not a backup, so the instructions travel with it.
cat >"$DEST/README.md" <<EOF
# Backup of \`$HOST\`

Taken from the running system on $(date -Is) with \`scripts/backup-system.sh\`
from this repository (omarchybook).

| file | what it is |
|---|---|
| \`$HOST-kernel-partition.img\` | raw copy of the ChromeOS kernel partition the system booted from (the signed FIT depthcharge loads) |
| \`$HOST-gpt-primary.img\` | the first 34 sectors of /dev/${ROOT_BLK:-disk}: protective MBR, GPT header, entry array |
| \`$HOST-gpt-backup.img\` | the last 33 sectors: the GPT's own backup copy |
| \`$HOST-gpt.bin\` | the same table as a portable \`sgdisk --load-backup\` file (when sgdisk is available) |
| \`$HOST-partitions.txt\` | readable partition table: \`cgpt show\` and \`lsblk\` with UUIDs |
| \`$HOST-boot.tar.gz\` | /boot, with owners, permissions, ACLs and xattrs |
| \`$HOST-rootfs.tar.gz\` | the root filesystem, /boot excluded |
| \`.backup-excludes.txt\` | what was deliberately left out (caches, build dirs, logs): all regenerable |
| SHA256SUMS | hashes of the archives and the kernel partition |

The tars are gzip so macOS' own \`tar\` can read them; the filesystem they sit on
(exFAT) cannot hold a Linux root filesystem by itself.

## Restoring

The supported way is the repository's own script, from the microSD-booted
system: \`sudo CONFIRM=yes scripts/restore-system.sh <this-directory>\`. It
refuses to run from the disk it would overwrite, checks SHA256SUMS before
writing anything, puts the original filesystem UUIDs back, and can prove itself
with \`DEEP=yes\` (a full \`tar -d\` comparison afterwards). The steps below are
what that script does, kept for reference.

1. Put the partition table back. On the same disk, the raw dumps are exact:
   \`\`\`sh
   total=\$(blockdev --getsz /dev/<disk>)
   sudo dd if=$HOST-gpt-primary.img of=/dev/<disk> bs=512 count=34 conv=fsync
   sudo dd if=$HOST-gpt-backup.img of=/dev/<disk> bs=512 seek=\$((total - 33)) count=33 conv=fsync
   sudo partx -d /dev/<disk>; sudo partx -a /dev/<disk>
   \`\`\`
   On a different disk use \`sgdisk --load-backup=$HOST-gpt.bin /dev/<disk>\`, or build
   the same three partitions with \`boot/lib-cgpt.sh\` from this repository
   (\`$HOST-partitions.txt\` records exactly what they were).
2. Kernel partition and /boot:
   \`\`\`sh
   sudo dd if=$HOST-kernel-partition.img of=/dev/<disk>p1 bs=1M conv=fsync
   sudo mkfs.ext4 -L pmOS_boot /dev/<disk>p2
   sudo mount /dev/<disk>p2 /mnt
   sudo tar -xpf $HOST-boot.tar.gz -C /mnt
   \`\`\`
3. Root filesystem. Keeping the original UUID ($ROOT_UUID) is what makes the
   restored system boot with its own \`/etc/fstab\` and kernel command line:
   \`\`\`sh
   sudo mkfs.ext4 -L pmOS_root /dev/<disk>p3
   sudo tune2fs -U $ROOT_UUID /dev/<disk>p3
   sudo mount /dev/<disk>p3 /mnt
   sudo tar -xpf $HOST-rootfs.tar.gz -C /mnt
   \`\`\`
4. If the UUIDs end up different, correct them in \`/etc/fstab\` and in the kernel
   command line (\`blkid\`, then \`boot/make-kpart.sh\`) before booting.

On a system installed by this port, a kernel update is completed for you: the
boot package's ALPM hook rebuilds p1 from the installed kernel the moment the
kernel package changes (\`99-omarchy-kpart.hook\` -> \`omarchy-google-boot
kpart-rewrite\`), and \`omarchy-google-boot update-verify\` proves p1 still holds
a signed FIT for the running release.
EOF

log "Checksums"
(
	cd "$DEST"
	for f in "$HOST-kernel-partition.img" "$HOST-gpt-primary.img" "$HOST-gpt-backup.img" \
		"$HOST-gpt.bin" "$HOST-boot.tar.gz" "$HOST-rootfs.tar.gz"; do
		if [ -f "$f" ]; then
			sha256sum "$f"
		fi
	done >SHA256SUMS
	cat SHA256SUMS
) | sed 's/^/  /'

log "Backup complete in $DEST"
ls -lh "$DEST" | sed 's/^/  /'
df -h "$DEST" | tail -1 | sed 's/^/  /'
