# shellcheck shell=bash
# Shared configuration for the omarchybook build system.
#
# The build is device-agnostic:
#   * a device lives in devices/<codename>/ and is described by a pmaports-style
#     `deviceinfo` (plus kernel-cmdline.conf and modules-initfs);
#   * the kernel to use is named by devices/<codename>/kernel and lives in
#     kernels/<flavor>/ (version, config.aarch64, patches/series).
#
# Select a device with the DEVICE environment variable. When only one device is
# present it is picked automatically.
#
# This file mirrors debian-aarch64's scripts/lib.sh; the boot-chain logic in
# ../boot/ is ported from that repository (see docs/plan.md §2.5).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the *invoking* user's home even when running under sudo, so large
# artifacts stay on the real filesystem and are not written to /root.
if [ -n "${SUDO_USER:-}" ]; then
	_invoking_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
	_invoking_home="$HOME"
fi
# /tmp is a small tmpfs on the target device; keep large artifacts on disk.
BUILD_ROOT="${BUILD_ROOT:-${_invoking_home:-/root}/.cache/omarchybook}"
WORK_DIR="${WORK_DIR:-$BUILD_ROOT/work}"
SRC_DIR="${SRC_DIR:-$BUILD_ROOT/src}"
mkdir -p "$WORK_DIR" "$SRC_DIR"

DEVICES_DIR="$REPO_DIR/devices"
KERNELS_DIR="$REPO_DIR/kernels"
PACKAGES_DIR="$REPO_DIR/packages"
BOOT_DIR="$REPO_DIR/boot"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "this command must run as root (use sudo)"; }

# ---------------------------------------------------------------------------
# Device
# ---------------------------------------------------------------------------
if [ -z "${DEVICE:-}" ]; then
	DEVICE="$(cd "$DEVICES_DIR" && ls -1 | head -n1)"
fi
DEVICE_DIR="$DEVICES_DIR/$DEVICE"
[ -d "$DEVICE_DIR" ] || die "unknown device '$DEVICE' (see $DEVICES_DIR)"

# deviceinfo is a sourceable shell file in pmaports format.
# shellcheck disable=SC1091
. "$DEVICE_DIR/deviceinfo"

DEVICE_ARCH="${deviceinfo_arch:-aarch64}"
# Kernel command line base (kernel-cmdline.conf) joined into one line.
# KERNEL_CMDLINE_OVERRIDE replaces it entirely; useful for a verbose debug boot
# (e.g. KERNEL_CMDLINE_OVERRIDE="console=tty0 ignore_loglevel loglevel=7").
KERNEL_CMDLINE="${KERNEL_CMDLINE_OVERRIDE:-$(tr '\n' ' ' <"$DEVICE_DIR/kernel-cmdline.conf" 2>/dev/null || true)}"
# Modules to force into the initramfs.
INITFS_MODULES="$(tr '\n' ' ' <"$DEVICE_DIR/modules-initfs" 2>/dev/null || true)"
# DTBs to embed (relative to /boot/dtbs; may contain a glob).
DTB_GLOB="${deviceinfo_dtb:-}"

# ---------------------------------------------------------------------------
# Kernel
# ---------------------------------------------------------------------------
KERNEL_FLAVOR="$(cat "$DEVICE_DIR/kernel")"
KERNEL_DIR="$KERNELS_DIR/$KERNEL_FLAVOR"
[ -d "$KERNEL_DIR" ] || die "kernel flavor '$KERNEL_FLAVOR' (device '$DEVICE') not found in $KERNELS_DIR"

KERNEL_VERSION="$(cat "$KERNEL_DIR/version")"
KERNEL_CONFIG="$KERNEL_DIR/config.aarch64"
KERNEL_PATCH_DIR="$KERNEL_DIR/patches"
# The Arch package name (docs/plan.md §3). It is NOT derived from the flavor:
# the flavor names the kernel source tree (mediatek-mt81), the package names the
# Omarchy kernel for this port (linux-omarchy-book), installed from [platform].
KERNEL_PACKAGE="${KERNEL_PACKAGE:-linux-omarchy-book}"
KERNEL_PACKAGE_HEADERS="${KERNEL_PACKAGE_HEADERS:-$KERNEL_PACKAGE-headers}"
# Kernel ARCH name (deviceinfo uses distro-style names).
case "$DEVICE_ARCH" in
	aarch64 | arm64) KERNEL_ARCH=arm64 ;;
	armv7 | arm) KERNEL_ARCH=arm ;;
	x86_64 | amd64) KERNEL_ARCH=x86 ;;
	*) KERNEL_ARCH="$DEVICE_ARCH" ;;
esac
# Derive the release string from the kernel config (no duplication).
KERNEL_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$KERNEL_CONFIG")"
# The release can be overridden for a kernel that was not built from this repo,
# e.g. the kernel a booted system is actually running (see install-kpart.sh).
KERNEL_RELEASE="${KERNEL_RELEASE:-${KERNEL_VERSION}${KERNEL_LOCALVERSION}}"

# Kernel image and initramfs paths inside the rootfs. The Arch `linux-<flavor>`
# package installs `vmlinuz-<release>` and a mkinitcpio preset named after it
# (docs/plan.md Phase 1), not Debian's `vmlinuz-`/`initrd.img-`. Overridable so
# a booted system whose kernel was not built here can still be re-kparted.
KERNEL_IMAGE_REL="${KERNEL_IMAGE_REL:-boot/vmlinuz-$KERNEL_RELEASE}"
INITRAMFS_REL="${INITRAMFS_REL:-boot/initramfs-$KERNEL_RELEASE.img}"

# ---------------------------------------------------------------------------
# Boot chain (depthcharge / ChromeOS GPT)
# ---------------------------------------------------------------------------
DEPTHCHARGE_BOARD="${deviceinfo_depthcharge_board:-}"
DEPTHCHARGE_COMPRESSION="${deviceinfo_depthcharge_compression:-lzma}"
# Vboot developer keys. The ALARM `vboot-utils` package ships cgpt/futility but
# no keys, so this repository vendors them (boot/devkeys/, docs/plan.md §4).
# Default to the vendored copy so a build away from the device is self-contained;
# depthchargectl falls back to /usr/share/vboot/devkeys when this one is absent.
DEPTHCHARGE_KEYDIR="${DEPTHCHARGE_KEYDIR:-$BOOT_DIR/devkeys}"
KPART_START_SECTORS="${deviceinfo_cgpt_kpart_start:-8192}"
KPART_SIZE_SECTORS="${deviceinfo_cgpt_kpart_size:-262144}"   # 128 MiB
KPART_PATH="${deviceinfo_cgpt_kpart:-/boot/vmlinuz.kpart}"
# The rest of the layout, after the kernel partition: a boot partition and the
# root filesystem (see boot/lib-cgpt.sh, which creates and resolves it).
# Both are ext4 by decision (docs/plan.md §3): no btrfs/snapper, because a
# snapshot cannot be booted from the ChromeOS kernel partition.
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-512}"
BOOT_FS="${BOOT_FS:-ext4}"

# ---------------------------------------------------------------------------
# Arch Linux ARM target
# ---------------------------------------------------------------------------
# aarch64 is published on the edge channel only, by both Omarchy and its mirror
# of Arch Linux ARM (docs/recon.md §5). [platform] is the local bundle built
# here and indexed with repo-add; it is not fetched.
CHANNEL="${CHANNEL:-edge}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-https://pkgs.omarchy.org/$CHANNEL/\$arch}"
ALARM_MIRROR="${ALARM_MIRROR:-https://arm-mirror.omarchy.org/\$arch/\$repo}"

# NetworkManager Wi-Fi profiles exported from the running system. They contain
# the PSK, so they deliberately live outside the repository.
WIFI_DIR="${WIFI_DIR:-$BUILD_ROOT/wifi}"

# Locale and timezone of the built image, baked into the rootfs:
#   LOCALE=en_US.UTF-8 scripts/build-rootfs.sh
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Mexico_City}"

# ---------------------------------------------------------------------------
# Build directories
# ---------------------------------------------------------------------------
ROOTFS="${ROOTFS:-$WORK_DIR/rootfs-$DEVICE}"
KERNEL_STAGE="${KERNEL_STAGE:-$WORK_DIR/kernel-stage-$KERNEL_FLAVOR}"
KPART="${KPART:-$WORK_DIR/$DEVICE.vmlinuz.kpart}"

export REPO_DIR BUILD_ROOT WORK_DIR SRC_DIR DEVICE DEVICE_DIR KERNEL_DIR
export WIFI_DIR LOCALE TIMEZONE
export KERNEL_PACKAGE KERNEL_PACKAGE_HEADERS
export BOOT_SIZE_MIB BOOT_FS KERNEL_RELEASE
