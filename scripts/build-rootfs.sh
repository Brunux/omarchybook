#!/bin/bash
# Build the Arch Linux ARM rootfs for the selected device.
#
# Bootstrap is the Arch Linux ARM aarch64 tarball, unpacked and then grown with
# pacman inside a chroot (a pacstrap equivalent that needs no
# arch-install-scripts on the build host). The system is built from
# packages/base.list plus devices/<codename>/packages.list, with
# packages/aarch64-filter.list applied, and the kernel comes from the local
# [platform] bundle (docs/plan.md Phase 2).
#
# Device: env DEVICE (default: the only one under devices/). Re-execs through
# sudo, forwarding every resolved build input (sudo does not preserve the
# caller's environment).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

TARGET_HOSTNAME="${TARGET_HOSTNAME:-$(echo "$DEVICE" | sed 's/.*-//')}"
USERNAME="${USERNAME:-omarchy}"
USERPASS="${USERPASS:-omarchy}"
PLATFORM_REPO="${PLATFORM_REPO:-$BUILD_ROOT/platform}"
PACMAN_CACHE="${PACMAN_CACHE:-$BUILD_ROOT/pacman-cache}"
ALARM_TARBALL="${ALARM_TARBALL:-ArchLinuxARM-aarch64-latest.tar.gz}"
ALARM_URL="${ALARM_URL:-http://os.archlinuxarm.org/os/$ALARM_TARBALL}"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" LOCALE="$LOCALE" TIMEZONE="$TIMEZONE" \
		TARGET_HOSTNAME="$TARGET_HOSTNAME" USERNAME="$USERNAME" USERPASS="$USERPASS" \
		PLATFORM_REPO="$PLATFORM_REPO" PACMAN_CACHE="$PACMAN_CACHE" ROOTFS="$ROOTFS" \
		CHANNEL="$CHANNEL" OMARCHY_MIRROR="$OMARCHY_MIRROR" ALARM_MIRROR="$ALARM_MIRROR" \
		"$(readlink -f "$0")" "$@"
fi

unmount_all() {
	for m in var/cache/pacman/pkg dev/pts dev proc sys; do
		umount -lf "$ROOTFS/$m" 2>/dev/null || true
	done
}
# Guard against the worst failure mode of a rebuild: deleting the rootfs while
# something is still mounted under it (a leftover bind of the host /dev or
# /proc), which would make `rm -rf` walk through into the host. Reads
# /proc/mounts directly so it does not depend on findmnt being installed.
assert_unmounted() {
	local left
	left="$(awk -v r="$ROOTFS/" 'index($2, r) == 1 { print $2 }' /proc/mounts)"
	[ -z "$left" ] || die "still mounted under $ROOTFS; refusing to proceed:
$left"
}
trap unmount_all EXIT

log "Device : $DEVICE ($DEVICE_ARCH)"
log "Kernel : $KERNEL_FLAVOR $KERNEL_RELEASE"
log "Rootfs : $ROOTFS"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
if [ ! -f "$SRC_DIR/$ALARM_TARBALL" ]; then
	log "Downloading $ALARM_URL"
	curl -fSL --retry 3 -o "$SRC_DIR/$ALARM_TARBALL" "$ALARM_URL"
fi

log "Extracting $ALARM_TARBALL into $ROOTFS"
unmount_all
assert_unmounted
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
# The tarball records a LIBARCHIVE xattr the host tar does not know; harmless.
tar -xpf "$SRC_DIR/$ALARM_TARBALL" -C "$ROOTFS" 2>/dev/null

log "Mounting virtual filesystems"
# A persistent package cache, so rebuilding the rootfs does not redownload.
mkdir -p "$PACMAN_CACHE"
mountpoint -q "$ROOTFS/var/cache/pacman/pkg" ||
	mount --bind "$PACMAN_CACHE" "$ROOTFS/var/cache/pacman/pkg"
for m in dev proc sys; do
	mountpoint -q "$ROOTFS/$m" || mount --bind "/$m" "$ROOTFS/$m"
done
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# ---------------------------------------------------------------------------
# pacman configuration
# ---------------------------------------------------------------------------
# pacman 7 sandboxes transactions with Landlock and an unprivileged `alpm`
# user; a build host whose kernel lacks Landlock aborts every transaction
# ("restricting filesystem access failed"). Disable the sandbox there. A device
# kernel has Landlock, but the line is kept so later build phases on the same
# host keep working.
sandbox=""
if ! grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then
	sandbox="DisableSandbox"
fi

log "Writing /etc/pacman.conf ([platform] -> [omarchy] -> ALARM)"
cat > "$ROOTFS/etc/pacman.conf" <<EOF
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
$sandbox

# [platform]: the local bundle built by this repository (our kernel, and any
# AUR-only package), indexed with repo-add. It is not fetched.
[platform]
SigLevel = Optional TrustAll
Server = file:///packages

# [omarchy]: Omarchy's own repository, published for aarch64 on the edge
# channel only. Installed in Phase 3; configured here.
[omarchy]
Server = ${OMARCHY_MIRROR}

[core]
Server = ${ALARM_MIRROR}

[extra]
Server = ${ALARM_MIRROR}

[alarm]
Server = ${ALARM_MIRROR}
EOF

log "Initializing the pacman keyring"
chroot "$ROOTFS" pacman-key --init
chroot "$ROOTFS" pacman-key --populate archlinuxarm

# ---------------------------------------------------------------------------
# [platform] bundle
# ---------------------------------------------------------------------------
log "Indexing the local [platform] bundle into /packages"
mkdir -p "$ROOTFS/packages"
shopt -s nullglob
platform_pkgs=("$PLATFORM_REPO"/*.pkg.tar.*)
shopt -u nullglob
((${#platform_pkgs[@]})) ||
	die "no packages in $PLATFORM_REPO; build the kernel first (Phase 1)"
cp "${platform_pkgs[@]}" "$ROOTFS/packages/"
# The glob must be expanded inside the chroot: on the host /packages does not
# exist, so an unquoted glob here would reach repo-add literally.
chroot "$ROOTFS" /bin/bash -c 'repo-add /packages/platform.db.tar.gz /packages/*.pkg.tar.*' >/dev/null
chroot "$ROOTFS" pacman -Sy

if ! chroot "$ROOTFS" pacman -Si "$KERNEL_PACKAGE" >/dev/null 2>&1; then
	die "the [platform] bundle does not carry $KERNEL_PACKAGE; build it first"
fi

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------
filter_list() {
	# Apply packages/aarch64-filter.list to package names on stdin.
	local filter="$PACKAGES_DIR/aarch64-filter.list"
	local -a drops=() from=() to=()
	local kw a b line name i d
	while read -r kw a b; do
		case "${kw:-}" in
			'' | '#'*) continue ;;
			drop) drops+=("$a") ;;
			replace)
				[ -n "${b:-}" ] || die "replace rule needs two names: $a"
				from+=("$a")
				to+=("$b")
				;;
			*) die "unknown aarch64-filter.list rule: $kw $a $b" ;;
		esac
	done < "$filter"

	while read -r line; do
		line="${line%%#*}"
		name="$(printf '%s' "$line" | tr -d '[:space:]')"
		[ -n "$name" ] || continue
		for d in "${drops[@]}"; do
			# shellcheck disable=SC2053
			[[ $name == $d ]] && continue 2
		done
		for i in "${!from[@]}"; do
			if [[ $name == "${from[i]}" ]]; then
				name="${to[i]}"
				break
			fi
		done
		printf '%s\n' "$name"
	done
}

install_list() {
	local list="$1"
	local -a names=()
	[ -f "$list" ] || die "missing package list: $list"
	mapfile -t names < <(filter_list < "$list")
	((${#names[@]})) || return 0
	log "Installing $(basename "$list") (${#names[@]} packages)"
	chroot "$ROOTFS" pacman -S --noconfirm --needed "${names[@]}"
}

# The ALARM tarball carries its own kernel; ours is the only one that may ship
# (the image boots a signed depthcharge FIT built from it).
log "Removing the bootstrap kernel"
chroot "$ROOTFS" pacman -Rdd --noconfirm linux-aarch64 2>/dev/null || true

# The tarball can lag the repositories (its systemd-resolvconf pins the systemd
# it shipped with), so upgrade in full first; otherwise the list install below
# fails with "installing systemd breaks dependency 'systemd=...'".
log "Upgrading the bootstrap system"
chroot "$ROOTFS" pacman -Syu --noconfirm

install_list "$PACKAGES_DIR/base.list"
install_list "$DEVICE_DIR/packages.list"

# ---------------------------------------------------------------------------
# System configuration
# ---------------------------------------------------------------------------
log "Configuring hostname, user, locale, timezone and services"
chroot "$ROOTFS" env \
	TARGET_HOSTNAME="$TARGET_HOSTNAME" \
	USERNAME="$USERNAME" USERPASS="$USERPASS" \
	LOCALE_TARGET="$LOCALE" TIMEZONE_TARGET="$TIMEZONE" \
	/bin/bash -euo pipefail -s <<'EOS'
set -euo pipefail
: "${TARGET_HOSTNAME:?}"
: "${USERNAME:?}"
: "${USERPASS:?}"
LOCALE="${LOCALE_TARGET:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE_TARGET:-America/Mexico_City}"

printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $TARGET_HOSTNAME.localdomain $TARGET_HOSTNAME
HOSTS

# /etc/locale.gen ships every entry commented out; uncomment the requested one
# (a name that is not in the file silently leaves the image with no UTF-8
# locale).
if grep -q "^# *$LOCALE " /etc/locale.gen; then
	sed -i "s|^# *$LOCALE |$LOCALE |" /etc/locale.gen
elif ! grep -q "^$LOCALE " /etc/locale.gen; then
	echo "locale '$LOCALE' is not in /etc/locale.gen, using en_US.UTF-8" >&2
	LOCALE=en_US.UTF-8
	sed -i 's|^# *en_US.UTF-8 |en_US.UTF-8 |' /etc/locale.gen
fi
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc 2>/dev/null || echo "hwclock skipped (no RTC access in chroot)"

# sd-vconsole warns loudly without this.
printf 'KEYMAP=us\n' > /etc/vconsole.conf

if ! id "$USERNAME" >/dev/null 2>&1; then
	useradd -m -G wheel -s /bin/bash "$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$USERPASS" | chpasswd
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

systemctl enable NetworkManager systemd-timesyncd sshd
EOS

log "Rootfs ready: $ROOTFS"
