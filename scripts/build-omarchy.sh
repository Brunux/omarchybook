#!/bin/bash
# Build the Omarchy runtime packages from a pinned quattro checkout with the
# vendored aarch64-google patch applied, and publish them into the local
# [platform] bundle (docs/plan.md Phase 3).
#
# Why build instead of install from [omarchy]: the released `omarchy` and
# `omarchy-settings` are built from basecamp/omarchy at a tag that predates
# platform detection, so they cannot carry the patch. omarchy-pkgs ships *-dev
# recipes pinned to the quattro tip that build from a local source tree
# (OMARCHY_SRC) -- the same recipes the ISO uses with --local-source. This script
# fetches that tree, applies upstream/omarchy/patches in series order, and runs
# makepkg for both. `omarchy-nvim` ships unpatched and is installed from
# [omarchy] by build-rootfs.sh.
#
# makepkg needs an Arch environment and the build host is not Arch, so the
# recipes run inside a chroot (BUILD_CHROOT). That chroot is a build tool: it is
# created here on first use and never becomes part of an image.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" PLATFORM_REPO="$PLATFORM_REPO" \
		OMARCHY_SRC_DIR="$OMARCHY_SRC_DIR" BUILD_CHROOT="$BUILD_CHROOT" \
		ALARM_MIRROR="$ALARM_MIRROR" \
		"$(readlink -f "$0")" "$@"
fi

ALARM_TARBALL="${ALARM_TARBALL:-ArchLinuxARM-aarch64-latest.tar.gz}"
ALARM_URL="${ALARM_URL:-http://os.archlinuxarm.org/os/$ALARM_TARBALL}"
# What the *-dev recipes list as makedepends: git is unused (we hand makepkg a
# local tree) but checked; magick really runs, rasterizing omarchy-settings'
# application icons.
BUILD_PACKAGES=(base-devel git imagemagick)

# The recipes to build. Both come from the same checkout; omarchy-dev depends on
# omarchy-settings-dev.
RECIPES=("$OMARCHY_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE")

unmount_build() {
	# Virtual filesystems this script bind-mounts into the chroot. Never the
	# chroot itself, and never recursive, so a stale entry cannot walk out.
	for m in sys proc dev; do
		umount -lf "$BUILD_CHROOT/$m" 2>/dev/null || true
	done
}
mount_build() {
	for m in dev proc sys; do
		mountpoint -q "$BUILD_CHROOT/$m" || mount --bind "/$m" "$BUILD_CHROOT/$m"
	done
	cp /etc/resolv.conf "$BUILD_CHROOT/etc/resolv.conf"
}
in_chroot() { chroot "$BUILD_CHROOT" "$@"; }

log "Source : $OMARCHY_SRC_DIR @ $OMARCHY_COMMIT"
log "Chroot : $BUILD_CHROOT"
log "Bundle : $PLATFORM_REPO"

# ---------------------------------------------------------------------------
# A build chroot with makepkg, created on first use
# ---------------------------------------------------------------------------
bootstrap_chroot() {
	log "Creating the build chroot at $BUILD_CHROOT"
	if [ ! -f "$SRC_DIR/$ALARM_TARBALL" ]; then
		curl -fSL --retry 3 -o "$SRC_DIR/$ALARM_TARBALL" "$ALARM_URL"
	fi
	mkdir -p "$BUILD_CHROOT"
	tar -xpf "$SRC_DIR/$ALARM_TARBALL" -C "$BUILD_CHROOT" 2>/dev/null

	# pacman 7 sandboxes transactions with Landlock; a build host without it
	# aborts every transaction (docs/recon.md).
	local sandbox=""
	grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || sandbox="DisableSandbox"
	cat > "$BUILD_CHROOT/etc/pacman.conf" <<EOF
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
$sandbox

[core]
Server = ${ALARM_MIRROR}

[extra]
Server = ${ALARM_MIRROR}

[alarm]
Server = ${ALARM_MIRROR}
EOF

	mount_build
	trap unmount_build EXIT
	in_chroot pacman-key --init
	in_chroot pacman-key --populate archlinuxarm
	in_chroot pacman -Syu --noconfirm
	in_chroot pacman -S --noconfirm --needed "${BUILD_PACKAGES[@]}"
}

if [ ! -x "$BUILD_CHROOT/usr/bin/makepkg" ]; then
	bootstrap_chroot
fi
# pacman's CheckSpace cannot resolve the chroot's root mount point on this build
# host, so every transaction aborts ("not enough free disk space"). The build
# chroot is a throwaway tool, not an image, so the check buys nothing here.
if grep -q '^CheckSpace' "$BUILD_CHROOT/etc/pacman.conf"; then
	sed -i 's/^CheckSpace/#CheckSpace/' "$BUILD_CHROOT/etc/pacman.conf"
fi
in_chroot id -u builder >/dev/null 2>&1 ||
	in_chroot useradd -m -s /bin/bash builder
missing=()
for p in "${BUILD_PACKAGES[@]}"; do
	in_chroot pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
done
if ((${#missing[@]})); then
	log "Installing build dependencies: ${missing[*]}"
	mount_build
	trap unmount_build EXIT
	in_chroot pacman -Sy --noconfirm
	in_chroot pacman -S --noconfirm --needed "${missing[@]}"
fi

# ---------------------------------------------------------------------------
# The pinned tree, with the proposal applied
# ---------------------------------------------------------------------------
if [ ! -d "$OMARCHY_SRC_DIR/.git" ]; then
	log "Fetching $OMARCHY_GIT"
	rm -rf "$OMARCHY_SRC_DIR"
	mkdir -p "$OMARCHY_SRC_DIR"
	git -C "$OMARCHY_SRC_DIR" init -q -b quattro
	git -C "$OMARCHY_SRC_DIR" remote add origin "$OMARCHY_GIT"
fi
git -C "$OMARCHY_SRC_DIR" fetch -q --depth 1 origin "$OMARCHY_COMMIT"
# Discard whatever a previous run left (patched files, untracked new files) so
# the tree is exactly the pinned commit before the series is applied.
git -C "$OMARCHY_SRC_DIR" checkout -q -f FETCH_HEAD
git -C "$OMARCHY_SRC_DIR" clean -qfd

log "Applying upstream/omarchy patches"
while read -r patch; do
	patch="${patch%%#*}"
	patch="$(printf '%s' "$patch" | tr -d '[:space:]')"
	[ -n "$patch" ] || continue
	git -C "$OMARCHY_SRC_DIR" apply --index --whitespace=nowarn "$OMARCHY_PATCH_DIR/$patch"
done < "$OMARCHY_PATCH_DIR/series"

# Rebuild only when the commit or the patch changed; the recipes are pure file
# copies, so a matching stamp means the published packages already say this.
stamp="$(printf 'commit=%s\n' "$OMARCHY_COMMIT"
	git -C "$OMARCHY_SRC_DIR" diff --cached)"
stamp_hash="$(printf '%s' "$stamp" | sha256sum | cut -d' ' -f1)"
have_all=1
for recipe in "${RECIPES[@]}"; do
	compgen -G "$PLATFORM_REPO/$recipe-*.pkg.tar.*" >/dev/null || have_all=0
done
if ((have_all)) && [ -f "$PLATFORM_REPO/.omarchy-stamp" ] &&
	[ "$(cat "$PLATFORM_REPO/.omarchy-stamp")" = "$stamp_hash" ]; then
	log "Up to date (stamp $stamp_hash); nothing to build"
	exit 0
fi

# ---------------------------------------------------------------------------
# Build inside the chroot
# ---------------------------------------------------------------------------
mount_build
trap unmount_build EXIT

build_dir="$BUILD_CHROOT/omarchy-build"
rm -rf "$build_dir"
mkdir -p "$build_dir/pkgbuilds" "$build_dir/src" "$build_dir/out"
cp -a "$OMARCHY_SRC_DIR/." "$build_dir/src/"
rm -rf "$build_dir/src/.git"
for recipe in "${RECIPES[@]}"; do
	[ -d "$OMARCHY_PKGS_DIR/$recipe" ] || die "no vendored recipe for $recipe"
	cp -a "$OMARCHY_PKGS_DIR/$recipe" "$build_dir/pkgbuilds/$recipe"
done
in_chroot chown -R builder:builder /omarchy-build

log "Building ${RECIPES[*]}"
in_chroot su -s /bin/bash builder -c "
	set -e
	export OMARCHY_SRC=/omarchy-build/src
	export PKGDEST=/omarchy-build/out
	export MAKEFLAGS='$MAKEFLAGS'
	for recipe in ${RECIPES[*]}; do
		echo \"==> makepkg \$recipe\"
		( cd /omarchy-build/pkgbuilds/\$recipe && makepkg -fc --noconfirm --noprogressbar --nodeps )
	done
"

# ---------------------------------------------------------------------------
# Publish into [platform]
# ---------------------------------------------------------------------------
mkdir -p "$PLATFORM_REPO"
for recipe in "${RECIPES[@]}"; do
	# One version at a time in the bundle: drop what this build replaces.
	rm -f "$PLATFORM_REPO/$recipe-"*.pkg.tar.*
done
shopt -s nullglob
built=("$build_dir/out"/*.pkg.tar.*)
shopt -u nullglob
((${#built[@]})) || die "makepkg produced no packages in $build_dir/out"
cp "${built[@]}" "$PLATFORM_REPO/"
printf '%s\n' "$stamp_hash" > "$PLATFORM_REPO/.omarchy-stamp"

log "Published into $PLATFORM_REPO:"
ls -1 "$PLATFORM_REPO/$OMARCHY_PACKAGE-"*.pkg.tar.* "$PLATFORM_REPO/$OMARCHY_SETTINGS_PACKAGE-"*.pkg.tar.*
