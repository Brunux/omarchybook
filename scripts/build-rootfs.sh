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

# The installed desktop set is about 9GiB before compression and the extraction
# and package cache want room on top of it. Running out mid-install fails deep
# inside a chroot ("No space left on device" from an unrelated mkdir) and costs
# the whole build, so check the budget up front.
avail_kib="$(df -Pk "$WORK_DIR" | awk 'NR == 2 { print $4 }')"
if [ "$avail_kib" -lt $((12 * 1024 * 1024)) ]; then
	die "not enough space in $WORK_DIR: $((avail_kib / 1024 / 1024))GiB free, need about 12GiB
makepkg work directories are the usual leak (docs/recon.md §9); reclaim them with:
	rm -rf $BUILD_CHROOT/build $WORK_DIR/rootfs-*"
fi

# The Omarchy runtime and settings carry the vendored aarch64-google patch, so
# they are built from the pinned checkout into [platform] before the bundle is
# indexed below (docs/plan.md Phase 3).
"$REPO_DIR/scripts/build-omarchy.sh"

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
# AUR-only package), indexed with repo-add and signed with the build key, whose
# public half is trusted below. Deliberately no SigLevel override: the global
# rule applies, so package signatures are required and the database's is not
# (repo-add is not given the private key -- it never enters the image).
[platform]
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

[aur]
Server = ${ALARM_MIRROR}
EOF

log "Initializing the pacman keyring"
chroot "$ROOTFS" pacman-key --init
chroot "$ROOTFS" pacman-key --populate archlinuxarm

# [omarchy] signs its database and packages with a key Arch Linux ARM's keyring
# does not carry, so trust the vendored copy before installing anything from it
# (keys/README.md).
log "Trusting the Omarchy signing key"
cp "$OMARCHY_KEY_FILE" "$ROOTFS/tmp/omarchy.gpg"
chroot "$ROOTFS" pacman-key --add /tmp/omarchy.gpg
chroot "$ROOTFS" pacman-key --lsign-key "$OMARCHY_SIGNING_KEY"
rm -f "$ROOTFS/tmp/omarchy.gpg"

# [platform] is signed with the build key (lib.sh), whose public half is handed
# to the image so the [platform] SigLevel above can require signatures.
log "Trusting the [platform] signing key"
ensure_platform_key
log "  fingerprint: $PLATFORM_KEY_FPR"
cp "$PLATFORM_KEY_FILE" "$ROOTFS/tmp/platform.pub"
chroot "$ROOTFS" pacman-key --add /tmp/platform.pub
chroot "$ROOTFS" pacman-key --lsign-key "$PLATFORM_KEY_FPR"
rm -f "$ROOTFS/tmp/platform.pub"

# ---------------------------------------------------------------------------
# [platform] bundle
# ---------------------------------------------------------------------------
sign_platform_packages
log "Indexing the local [platform] bundle into /packages"
mkdir -p "$ROOTFS/packages"
shopt -s nullglob
platform_pkgs=("$PLATFORM_REPO"/*.pkg.tar.*)
shopt -u nullglob
((${#platform_pkgs[@]})) ||
	die "no packages in $PLATFORM_REPO; build the kernel first (Phase 1)"
cp "${platform_pkgs[@]}" "$ROOTFS/packages/"

# Refresh the persistent cache with the same files. pacman reuses a cached file
# that merely has the right name, and this bundle republishes a package under an
# unchanged version whenever its recipe or patch changes (the build stamps are
# content-based, not version-based), so a stale entry would fail the repository
# checksum at install time and abort the whole transaction.
cp -f "${platform_pkgs[@]}" "$PACMAN_CACHE/"

# The find must run inside the chroot: on the host /packages does not exist.
# Only the packages themselves are passed -- repo-add reads each `.sig` next to
# its package (that is where %PGPSIG% comes from) but would choke on them as
# arguments.
chroot "$ROOTFS" /bin/bash -c \
	'repo-add /packages/platform.db.tar.gz $(find /packages -maxdepth 1 -name "*.pkg.tar.*" ! -name "*.sig")' >/dev/null
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

# The image manifest goes in before anything is installed. The detector
# (omarchy-hw-platform) answers from this file inside a chroot and deliberately
# never reads the build host's device tree -- an image is built away from the
# machine it will run on -- so whichever package setup runs during the lists
# below must find the target named here rather than the builder. Note that the
# boot package's ALPM hook still cannot check the platform when the device list
# installs the kernel: its detector ships with the runtime, which comes later,
# so it reports that it cannot tell and does nothing (docs/recon.md §12).
log "Pinning platform=$OMARCHY_PLATFORM in the image manifest"
mkdir -p "$ROOTFS/var/lib/omarchy/image"
chmod 0755 "$ROOTFS/var/lib/omarchy/image"
printf 'format=1\nplatform=%s\n' "$OMARCHY_PLATFORM" \
	> "$ROOTFS/var/lib/omarchy/image/target"
chmod 0644 "$ROOTFS/var/lib/omarchy/image/target"

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

# ---------------------------------------------------------------------------
# Phase 3 -- the Omarchy layer
# ---------------------------------------------------------------------------
# The runtime, settings and editor, plus the desktop set composed from the
# checkout's own lists. The image manifest is already in place (written before
# the package lists above): it makes the detector answer aarch64-google inside
# the chroot, so package setup describes the target rather than the builder, and
# it queues the hardware leaves to the machine's first boot (docs/recon.md §2).

# The desktop set: omarchy-base.packages plus the aarch64 additions and the
# platform's own, minus the packages the runtime marks x86_64-only. The same
# composition omarchy-pkg-defaults and the ISO's aarch64_default_set produce.
compose_omarchy_set() {
	local dir="$OMARCHY_SRC_DIR/install"
	local skip="$dir/omarchy-x86_64-only.packages"
	local -a lists=("$dir/omarchy-base.packages" "$dir/omarchy-aarch64.packages")
	local platform_list="$dir/omarchy-aarch64-$OMARCHY_PLATFORM.packages"
	[ -f "$platform_list" ] && lists+=("$platform_list")
	awk -v skips="$skip" '
		BEGIN { while ((getline line < skips) > 0) { sub(/[ \t]*#.*$/, "", line); if (line != "") skip[line] = 1 } }
		{ sub(/[ \t]*#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
		$0 == "" { next }
		skip[$0] { next }
		!seen[$0]++
	' "${lists[@]}"
}

log "Installing the Omarchy package set"
# omarchy-settings' install scriptlet takes a lock under /run/lock before it
# declares the package installed; the ALARM tarball has no /run/lock (systemd
# creates it on a booted machine), so give the chroot one.
mkdir -p "$ROOTFS/run/lock"
chmod 0755 "$ROOTFS/run" "$ROOTFS/run/lock"
mapfile -t omarchy_names < <(
	compose_omarchy_set | filter_list
	filter_list < "$PACKAGES_DIR/omarchy.list"
)
mapfile -t omarchy_names < <(printf '%s\n' "${omarchy_names[@]}" | awk '!seen[$0]++')
chroot "$ROOTFS" pacman -S --noconfirm --needed "${omarchy_names[@]}"

# The installer's own root phases (config, hardware, login, post-install), the
# way `omarchy apply system` runs them. The hardware leaves see the manifest and
# queue themselves for first boot instead of describing this build host.
log "Running the Omarchy system setup"
if ! chroot "$ROOTFS" env USERNAME="$USERNAME" \
	/bin/bash -euo pipefail -c \
	'omarchy-apply-system --install-user "$USERNAME" --first-install'; then
	tail -n 100 "$ROOTFS/var/log/omarchy-install.log" >&2 || true
	die "omarchy-apply-system failed (see /var/log/omarchy-install.log in the rootfs)"
fi

# Plan §3's whole pinning policy: nothing but IgnorePkg for the linux-omarchy
# family, so an update can never pull a different kernel over the one this port
# ships. The post-install leaf wrote Omarchy's own pacman.conf a moment ago, so
# the pin is added after it, and inside [options] where pacman expects it.
log "Pinning the linux-omarchy family in /etc/pacman.conf"
ignore_pkgs="linux-omarchy linux-omarchy-headers linux-omarchy-book linux-omarchy-book-headers"
if grep -q '^IgnorePkg' "$ROOTFS/etc/pacman.conf"; then
	sed -i "s|^IgnorePkg *=.*|IgnorePkg = $ignore_pkgs|" "$ROOTFS/etc/pacman.conf"
else
	sed -i "/^\[options\]/a IgnorePkg = $ignore_pkgs" "$ROOTFS/etc/pacman.conf"
fi

# The per-user phases /etc/skel cannot seed, as the user (the command refuses
# to run as root). With --first-install the command treats itself as the ISO's
# install chroot, and that context's offline path unpacks the Node.js tarball
# the ISO bundles in /opt/packages (install/user/mise-work.sh), so stage the
# same one. The ISO's builder picks it out of the nodejs.org release manifest
# and checks it (builder/node-release.sh + build-iso.sh); do the same and keep
# it under src/ so a rebuild does not fetch it again.
node_platform=linux-x64
[ "$DEVICE_ARCH" = aarch64 ] && node_platform=linux-arm64
node_tarball="$(find "$SRC_DIR" -maxdepth 1 -name "node-v*-$node_platform.tar.gz" -print -quit)"
if [ -z "$node_tarball" ]; then
	log "Downloading the bundled Node.js ($node_platform) for the offline mise install"
	node_manifest="$(curl -fsSL https://nodejs.org/dist/latest/SHASUMS256.txt)" ||
		die "could not fetch https://nodejs.org/dist/latest/SHASUMS256.txt"
	node_row="$(awk -v suffix="-$node_platform.tar.gz" '
		length($2) >= length(suffix) &&
			substr($2, length($2) - length(suffix) + 1) == suffix {
			if (found) { duplicate = 1; next }
			sha = $1; filename = $2; found = 1
		}
		END { if (!found || duplicate) exit 1; print sha "  " filename }
	' <<<"$node_manifest")" ||
		die "no single Node.js $node_platform tarball in SHASUMS256.txt"
	node_name="${node_row#*  }"
	node_tarball="$SRC_DIR/$node_name"
	curl -fSL --retry 3 -o "$node_tarball" "https://nodejs.org/dist/latest/$node_name" ||
		die "could not download $node_name"
	printf '%s  %s\n' "${node_row%%  *}" "$node_tarball" | sha256sum -c - ||
		die "checksum mismatch for $node_name"
fi

log "Staging the bundled Node.js in the image's /opt/packages"
mkdir -p "$ROOTFS/opt/packages"
cp "$node_tarball" "$ROOTFS/opt/packages/"

log "Provisioning the user '$USERNAME'"
chroot "$ROOTFS" su - "$USERNAME" -c 'omarchy-provision-user --first-install'

# The ISO injects /opt/packages with a bind mount for the install only, and the
# installed system does not keep it, so neither does the image.
rm -rf "$ROOTFS/opt/packages"

log "Rootfs ready: $ROOTFS"
