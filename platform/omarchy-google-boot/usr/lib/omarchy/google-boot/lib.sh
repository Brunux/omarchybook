# shellcheck shell=bash
# Shared configuration for the boot chain on an installed system.
#
# boot/make-kpart.sh and boot/install-kpart.sh source a lib that sits beside
# them, so that the same files work in this repository -- where boot/lib.sh is a
# thin wrapper around scripts/lib.sh, which knows about checkouts, build trees
# and rootfs directories -- and on the device, where this file replaces it.
#
# Everything below is derived from what this package ships: the deviceinfo and
# the kernel command line the build host uses too (extra.list), and the kernel
# release the system is actually running. Nothing device-specific is typed twice.
set -euo pipefail

_boot_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The device this system is, described by the very deviceinfo the build host
# reads (pmaports format, a sourceable shell file).
# shellcheck disable=SC1091
. "$_boot_dir/deviceinfo"
DEVICE="${deviceinfo_codename:-google-asurada}"
# make-kpart.sh's glob: DTBs live under /boot/dtbs/<vendor>/ and hayato's must
# sort first, because the FIT's default config is the first one.
DTB_GLOB="${deviceinfo_dtb:-}"
# depthchargectl's board name: the SoC (mt8192), not the board (docs/plan.md §4).
DEPTHCHARGE_BOARD="${deviceinfo_depthcharge_board:-}"
DEPTHCHARGE_COMPRESSION="${deviceinfo_depthcharge_compression:-lzma}"
KPART_START_SECTORS="${deviceinfo_cgpt_kpart_start:-8192}"
KPART_SIZE_SECTORS="${deviceinfo_cgpt_kpart_size:-262144}"

# The vboot keys depthchargectl needs. ALARM's vboot-utils ships none
# (docs/recon.md §7), so this package carries ChromiumOS' well-known developer
# keys: the device boots dev-signed (dev_boot_signed_only=0), which is what makes
# them the right keys to re-sign a kernel update with.
DEPTHCHARGE_KEYDIR="${DEPTHCHARGE_KEYDIR:-$_boot_dir/devkeys}"

# The kernel this system runs. install-kpart.sh exports it from `uname -r`
# before calling make-kpart.sh; the fallback covers a direct call.
KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
KERNEL_IMAGE_REL="${KERNEL_IMAGE_REL:-boot/vmlinuz-$KERNEL_RELEASE}"
INITRAMFS_REL="${INITRAMFS_REL:-boot/initramfs-$KERNEL_RELEASE.img}"

# The platform-independent command line, from the same file the build host uses,
# plus the verbose-boot escape hatch of plan §4.
KERNEL_CMDLINE="${KERNEL_CMDLINE_OVERRIDE:-$(tr '\n' ' ' <"$_boot_dir/kernel-cmdline.conf")}"

# A booted system is its own rootfs; the work directory holds the FIT built
# during a kernel update and the backup install-kpart.sh takes first.
ROOTFS="${ROOTFS:-/}"
WORK_DIR="${WORK_DIR:-/var/lib/omarchy-google-boot}"
mkdir -p "$WORK_DIR"
KPART="${KPART:-$WORK_DIR/$DEVICE.vmlinuz.kpart}"

# The rest of the layout, which boot/lib-cgpt.sh needs when it writes a disk
# (plan §3: both are ext4, no btrfs/snapper -- a snapshot cannot be booted from
# the kernel partition).
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-512}"
BOOT_FS="${BOOT_FS:-ext4}"
