#!/bin/bash
# Rewrite the ChromeOS kernel partition this system was booted from.
#
# Counterpart of boot-deploy's flash_updated_depthcharge_kernel(): a machine
# that boots from a ChromeOS kernel partition keeps the kernel *inside* that
# partition, so installing a new kernel into /boot and /lib/modules is not
# enough -- the partition has to be rewritten too, or the firmware goes on
# loading the old kernel while the rest of the system moves on.
#
# The partition is not assumed or configured: it is the one depthcharge
# substituted into kern_guid= in /proc/cmdline, so this always acts on the
# device it is running from (card or eMMC).
#
# Usage: install-kpart.sh [KPART_IMAGE]
#
# Without an argument the kpart is built from the running system (its kernel
# release, /boot and the DTBs there), which is what a kernel update needs. With
# an argument that prebuilt image is written instead (e.g. the one the build
# host produced). Writing requires CONFIRM=yes and what it replaces is backed up
# first.
#
# Ported from debian-aarch64 (docs/plan.md §2.5). The paths are Arch's
# (vboot-utils' futility, util-linux's findfs/lsblk/findmnt), the scripts source
# their lib from beside themselves so the packaged copy works on the device, and
# the ALPM hook (boot/99-omarchy-kpart.hook via `omarchy-google-boot
# kpart-rewrite`) is this same script with CONFIRM=yes -- that is the trigger the
# Debian side had in install-kernel.sh. The chroot guard it inherited did not
# work and lives in lib-cgpt.sh now (docs/recon.md §12).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib-cgpt.sh"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n "$(readlink -f "$0")" "$@"
fi

# Never act from a chroot: /proc/cmdline there belongs to the host, so the GUID
# would point at the host's kernel partition (the check lives in lib-cgpt.sh so
# every boot-chain script uses the same one).
require_real_root

GUID=""
for _x in $(cat /proc/cmdline); do
	case "$_x" in
		kern_guid=*) GUID="${_x#kern_guid=}" ;;
	esac
done
[ -n "$GUID" ] || die "no kern_guid= in /proc/cmdline: this kernel was not loaded by depthcharge"
PART="$(findfs PARTUUID="$GUID" 2>/dev/null || true)"
[ -n "$PART" ] || die "no partition with PARTUUID=$GUID (from kern_guid in /proc/cmdline)"
DISK="/dev/$(lsblk -nro PKNAME "$PART")"
log "Kernel partition: $PART (disk $DISK, PARTUUID $GUID)"

ROOT_UUID="$(findmnt -n -o UUID / 2>/dev/null || true)"
[ -n "$ROOT_UUID" ] || ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
[ -n "$ROOT_UUID" ] || die "could not read the UUID of the root filesystem"

if [ -n "${1:-}" ]; then
	IMG="$(readlink -f "$1")"
	[ -f "$IMG" ] || die "not a file: $IMG"
	log "Using the prebuilt kpart $IMG"
else
	# The running kernel, not the repository's: that is the one /lib/modules and
	# /boot describe right now.
	KERNEL_RELEASE="$(uname -r)"
	export KERNEL_RELEASE
	[ -d "/lib/modules/$KERNEL_RELEASE" ] || die "no /lib/modules/$KERNEL_RELEASE"
	IMG="$WORK_DIR/kpart-running-$DEVICE"
	log "Building the kpart from the running system ($KERNEL_RELEASE)"
	# ROOTFS=/ so the kernel, the initramfs and the DTBs are the installed ones.
	"$(dirname "$0")/make-kpart.sh" / "$IMG" "root=UUID=$ROOT_UUID rootwait rw"
fi

kpart_fits "$IMG" "$PART"
kpart_verify "$IMG"

# The partition looked up from kern_guid has to be a ChromeOS kernel partition,
# not merely a partition: writing a kpart into the root filesystem because a
# GUID was wrong would be unrecoverable.
_idx="$(printf '%s' "$PART" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)$/\1/p')"
if [ -n "$_idx" ] && command -v cgpt >/dev/null 2>&1; then
	_table="$(cgpt show -i "$_idx" "$DISK" 2>/dev/null || true)"
	case "$_table" in
		*"ChromeOS kernel"*) ;;
		*) die "$PART is not a ChromeOS kernel partition (kernel partition expected)" ;;
	esac
	log "Plan: write $IMG ($(stat -c %s "$IMG") bytes) to $PART"
	printf '%s\n' "$_table"
else
	log "Plan: write $IMG ($(stat -c %s "$IMG") bytes) to $PART"
fi
[ "${CONFIRM:-}" = "yes" ] || die "refusing to write without CONFIRM=yes (CONFIRM=yes install-kpart.sh)"

# Keep a copy of what was there, so a bad image is recoverable without going
# back to a microSD.
BACKUP="$WORK_DIR/kpart-backup-$(date +%Y%m%d-%H%M%S).img"
log "Backing up the current kernel partition to $BACKUP"
log "  (recover with: dd if=$BACKUP of=$PART bs=1M conv=fsync)"
dd if="$PART" of="$BACKUP" bs=1M status=none

log "Writing the kpart"
dd if="$IMG" of="$PART" bs=1M conv=fsync status=none
sync

futility show "$PART" 2>/dev/null | grep -E 'Kernel partition|Header version|Body verification' ||
	warn "could not re-read the kernel partition with futility"

log "Done. Reboot to run the new kernel; keep $BACKUP until it has booted."
