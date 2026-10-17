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

# Sizes in MiB, without GNU-only options: the build host's du is BusyBox (no
# --apparent-size, no -B), so ask for KiB and divide. `du -x` keeps a lingering
# bind mount (the pacman cache, say) out of the count.
du_mib()   { du -sxk "$1" 2>/dev/null | awk '{ print int(($1 + 1023) / 1024) }'; }
file_mib() { echo $(( ($(stat -c %s "$1") + 1048575) / 1048576 )); }

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

# ---------------------------------------------------------------------------
# Omarchy layer (Phase 3)
# ---------------------------------------------------------------------------
# The runtime and settings packages must carry the vendored aarch64-google patch
# (upstream/omarchy/), so they are built here from a pinned quattro checkout
# with omarchy-pkgs' *-dev recipes — the ISO's --local-source model — and
# published into [platform]. The released `omarchy`/`omarchy-settings` are built
# from basecamp/omarchy at a tag that predates platform detection.
# omarchy-nvim ships unpatched and comes from [omarchy].
OMARCHY_GIT="${OMARCHY_GIT:-https://github.com/omacom/omarchy.git}"
OMARCHY_COMMIT="${OMARCHY_COMMIT:-51bfd1dbaa1b5f790e19623faf2745945d40c796}"
OMARCHY_SRC_DIR="${OMARCHY_SRC_DIR:-$SRC_DIR/omarchy}"
OMARCHY_PATCH_DIR="$REPO_DIR/upstream/omarchy/patches"
OMARCHY_PKGS_DIR="$REPO_DIR/upstream/omarchy-pkgs/pkgbuilds"
OMARCHY_PACKAGE="${OMARCHY_PACKAGE:-omarchy-dev}"
OMARCHY_SETTINGS_PACKAGE="${OMARCHY_SETTINGS_PACKAGE:-omarchy-settings-dev}"
OMARCHY_NVIM_PACKAGE="${OMARCHY_NVIM_PACKAGE:-omarchy-nvim}"
OMARCHY_KEYRING_PACKAGE="${OMARCHY_KEYRING_PACKAGE:-omarchy-keyring}"
OMARCHY_SIGNING_KEY="${OMARCHY_SIGNING_KEY:-40DFB630FF42BCFFB047046CF0134EE680CAC571}"
OMARCHY_KEY_FILE="${OMARCHY_KEY_FILE:-$REPO_DIR/keys/omarchy.gpg}"
# The platform an image manifest pins (/var/lib/omarchy/image/target): the name
# omarchy-hw-platform maps to aarch64-google. It makes the build describe the
# target rather than the builder and defers the hardware leaves to first boot
# (docs/recon.md §2).
OMARCHY_PLATFORM="${OMARCHY_PLATFORM:-google}"
# An Arch environment to build packages in (makepkg needs one; the build host is
# not Arch). Created on demand by build-omarchy.sh; never part of the image.
BUILD_CHROOT="${BUILD_CHROOT:-$BUILD_ROOT/build-chroot}"

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
# The local package bundle indexed into the image at /packages, and the shared
# pacman cache that survives rootfs rebuilds.
PLATFORM_REPO="${PLATFORM_REPO:-$BUILD_ROOT/platform}"
PACMAN_CACHE="${PACMAN_CACHE:-$BUILD_ROOT/pacman-cache}"

# ---------------------------------------------------------------------------
# Build parallelism
# ---------------------------------------------------------------------------
# makepkg does not set MAKEFLAGS by itself (Arch ships it commented out in
# makepkg.conf) and `make` without -j builds serially, so a recipe that does not
# get it here silently uses one core: the first kernel builds in this repository
# ran for hours that way (docs/recon.md §9). Cap by memory as well as by cores --
# one kernel compile job spends a few hundred MiB and the build host here has
# under 4 GiB. Override with JOBS=n or MAKEFLAGS=... when needed.
JOBS="${JOBS:-$(nproc)}"
_mem_gib=$(( ($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) + 1048575) / 1048576 ))
[ "$JOBS" -le "$_mem_gib" ] || JOBS="$_mem_gib"
[ "$JOBS" -ge 1 ] || JOBS=1
MAKEFLAGS="${MAKEFLAGS:--j$JOBS}"
export JOBS MAKEFLAGS

# ---------------------------------------------------------------------------
# [platform] signing key
# ---------------------------------------------------------------------------
# The bundle is signed with a build/release key that lives outside the
# repository: a private key is never committed, and keys/ carries only the
# public key [omarchy] signs with. The key is created on first use (below) and
# its public half is what a build trusts for [platform] (build-rootfs.sh).
# Keeping the bundle signed now is what a device-side [platform] repository
# would need later (docs/recon.md §8), and it exercises the trust chain while
# the bundle is still a build-time one.
PLATFORM_KEY_UID="${PLATFORM_KEY_UID:-Omarchy Book Build <build@omarchybook.invalid>}"
PLATFORM_GNUPGHOME="${PLATFORM_GNUPGHOME:-$BUILD_ROOT/keys/gnupg}"
PLATFORM_KEY_FILE="${PLATFORM_KEY_FILE:-$BUILD_ROOT/keys/platform.pub}"

# The upgrade path for a *published* image (plan Phase 6, docs/recon.md 9).
# Omarchy's own post-install leaf rewrites /etc/pacman.conf and drops the
# build-time [platform], so neither linux-omarchy-book nor omarchy-google can
# ever be updated on a device. A release publishes the bundle as a repository
# (scripts/make-release.sh: platform/) and, when this is set to where that
# directory is served, build-rootfs.sh writes the [platform] section back into
# the image -- the signing key is already trusted there, so the URL is the only
# missing piece. Empty (the default) keeps an unreleased build exactly as it was:
# no repository a machine could fail to reach.
PLATFORM_REPO_URL="${PLATFORM_REPO_URL:-}"

platform_key_fingerprint() {
	GNUPGHOME="$PLATFORM_GNUPGHOME" gpg --batch --with-colons \
		--list-keys "$PLATFORM_KEY_UID" 2>/dev/null |
		awk -F: '/^fpr:/ { print $10; exit }'
}

ensure_platform_key() {
	# gpg refuses a keyring other users can read, and wants to create its files
	# in a directory that already exists.
	mkdir -p "$PLATFORM_GNUPGHOME"
	chmod 700 "$PLATFORM_GNUPGHOME"
	if [ -z "$(platform_key_fingerprint)" ]; then
		log "Creating the [platform] signing key ($PLATFORM_KEY_UID)"
		log "  keyring: $PLATFORM_GNUPGHOME"
		GNUPGHOME="$PLATFORM_GNUPGHOME" gpg --batch \
			--pinentry-mode loopback --passphrase '' \
			--quick-gen-key "$PLATFORM_KEY_UID" ed25519 sign 0
	fi
	PLATFORM_KEY_FPR="$(platform_key_fingerprint)"
	[ -n "$PLATFORM_KEY_FPR" ] ||
		die "no [platform] signing key in $PLATFORM_GNUPGHOME"
	GNUPGHOME="$PLATFORM_GNUPGHOME" gpg --batch --armor \
		--export "$PLATFORM_KEY_FPR" > "$PLATFORM_KEY_FILE"
	export PLATFORM_KEY_FPR
}

# Detached binary signatures next to each package in the bundle: that is what
# pacman verifies and what repo-add copies into the database as %PGPSIG%.
# Idempotent: a package whose signature is already newer than it is left alone.
sign_platform_packages() {
	[ -d "$PLATFORM_REPO" ] || return 0
	ensure_platform_key
	local pkg
	for pkg in "$PLATFORM_REPO"/*.pkg.tar.*; do
		[ -f "$pkg" ] || continue
		case "$pkg" in *.sig) continue ;; esac
		if [ -f "$pkg.sig" ] && [ "$pkg.sig" -nt "$pkg" ]; then
			continue
		fi
		log "Signing $(basename "$pkg")"
		GNUPGHOME="$PLATFORM_GNUPGHOME" gpg --batch --yes --no-armor \
			--local-user "$PLATFORM_KEY_FPR" --detach-sign "$pkg"
	done
}

export REPO_DIR BUILD_ROOT WORK_DIR SRC_DIR DEVICE DEVICE_DIR KERNEL_DIR
export WIFI_DIR LOCALE TIMEZONE
export KERNEL_PACKAGE KERNEL_PACKAGE_HEADERS
export BOOT_SIZE_MIB BOOT_FS KERNEL_RELEASE
export PLATFORM_REPO PACMAN_CACHE
export PLATFORM_REPO_URL
export PLATFORM_KEY_UID PLATFORM_GNUPGHOME PLATFORM_KEY_FILE
export OMARCHY_GIT OMARCHY_COMMIT OMARCHY_SRC_DIR OMARCHY_PATCH_DIR
export OMARCHY_PKGS_DIR OMARCHY_PACKAGE OMARCHY_SETTINGS_PACKAGE
export OMARCHY_NVIM_PACKAGE OMARCHY_KEYRING_PACKAGE OMARCHY_SIGNING_KEY
export OMARCHY_KEY_FILE OMARCHY_PLATFORM BUILD_CHROOT
