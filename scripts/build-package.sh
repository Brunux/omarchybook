#!/bin/bash
# Build vendored recipes into the local [platform] bundle (docs/plan.md §4).
#
# Usage: build-package.sh <recipe-dir> [<recipe-dir> ...]
#
# Exists for the recipes that are neither ours nor Omarchy's: the AUR-only
# packages the device needs and no configured repository carries, today
# `upstream/depthcharge-tools` (docs/plan.md §8, docs/recon.md §7). A kernel
# flavor is a recipe too, and `kernels/<flavor>` goes through here as well --
# scripts/build-kernel.sh is only the wrapper that says why.
#
# makepkg needs an Arch environment and this build host is not Arch, so recipes
# run inside the same throwaway chroot the other builders use (created here on
# first use, never part of an image). Do not run two builders at once: they
# share the chroot, and dependency installs are pacman transactions.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

(( $# )) || die "usage: $(basename "$0") <recipe-dir> [<recipe-dir> ...]"

# Resolve the recipes before the sudo re-exec: sudo keeps the working directory,
# but the caller may have reached us through a wrapper from somewhere else.
recipes=()
for recipe in "$@"; do
	[ -d "$recipe" ] || die "no such recipe directory: $recipe"
	[ -f "$recipe/PKGBUILD" ] || die "no PKGBUILD in $recipe"
	recipes+=("$(readlink -f "$recipe")")
done

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" PLATFORM_REPO="$PLATFORM_REPO" \
		PLATFORM_GNUPGHOME="$PLATFORM_GNUPGHOME" \
		PLATFORM_KEY_FILE="$PLATFORM_KEY_FILE" \
		BUILD_CHROOT="$BUILD_CHROOT" ALARM_MIRROR="$ALARM_MIRROR" \
		"$(readlink -f "$0")" "${recipes[@]}"
fi

ALARM_TARBALL="${ALARM_TARBALL:-ArchLinuxARM-aarch64-latest.tar.gz}"
ALARM_URL="${ALARM_URL:-http://os.archlinuxarm.org/os/$ALARM_TARBALL}"
BUILD_PACKAGES=(base-devel)

unmount_build() {
	# Virtual filesystems this script bind-mounts into the chroot. Never the
	# chroot itself, and never recursive, so a stale entry cannot walk out.
	for m in sys proc dev; do
		umount -lf "$BUILD_CHROOT/$m" 2>/dev/null || true
	done
}
mount_build() {
	device_nodes "$BUILD_CHROOT"
	for m in dev proc sys; do
		mountpoint -q "$BUILD_CHROOT/$m" || mount --bind "/$m" "$BUILD_CHROOT/$m"
	done
	resolv_conf "$BUILD_CHROOT"
}
in_chroot() { chroot "$BUILD_CHROOT" "$@"; }

# Content-addressed over the whole recipe: PKGBUILD, version/config, patches and
# patches/series (whose order is part of the recipe), any local sources.
recipe_hash() {
	(cd "$1" && find . -type f -exec sha256sum {} + |
		LC_ALL=C sort | sha256sum | cut -d' ' -f1)
}

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
	# The tarball ships pacman and makepkg already, so neither can mark a
	# bootstrapped chroot; the keyring that pacman-key --init creates is the real
	# marker. Unpack only when there is nothing there, so a re-run after a failed
	# bootstrap continues instead of unpacking 790 MiB again.
	if [ ! -x "$BUILD_CHROOT/usr/bin/pacman" ]; then
		tar -xpf "$SRC_DIR/$ALARM_TARBALL" -C "$BUILD_CHROOT" 2>/dev/null
	fi

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

if [ ! -d "$BUILD_CHROOT/etc/pacman.d/gnupg" ]; then
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
# Build each recipe
# ---------------------------------------------------------------------------
mount_build
trap unmount_build EXIT

for recipe in "${recipes[@]}"; do
	name="$(basename "$recipe")"
	build_dir="$BUILD_CHROOT/pkg-build/$name"

	log "Recipe : $name ($recipe)"

	# SRCDEST is kept between runs (a kernel tarball is a download worth
	# keeping) and so is makepkg's work tree, $build_dir/recipe/src: it is what
	# lets an interrupted build -- or a re-run after a packaging failure --
	# resume from the objects it already has instead of recompiling for an hour.
	# The recipe files are refreshed over that tree every run.
	rm -rf "$build_dir/out"
	mkdir -p "$build_dir/recipe" "$build_dir/out" "$build_dir/src"
	cp -a "$recipe/." "$build_dir/recipe/"

	# A recipe may need files that live outside it. The boot chain is canonical
	# in the repository's boot/ (plan §4: the canonical copy, consumed by
	# scripts/), but the package that ships it to the device is
	# platform/omarchy-book-boot; `extra.list` names those paths, one
	# repository-relative path per line, and they are staged under
	# recipe/extra/ for the recipe's install step to pick up. They count towards
	# the recipe's hash, so a change in boot/ rebuilds the package.
	extra_paths=()
	if [ -f "$recipe/extra.list" ]; then
		while read -r path; do
			path="${path%%#*}"
			path="$(printf '%s' "$path" | tr -d '[:space:]')"
			[ -n "$path" ] || continue
			[ -e "$REPO_DIR/$path" ] || die "$name: extra.list names a missing path: $path"
			extra_paths+=("$path")
			mkdir -p "$build_dir/recipe/extra/$(dirname "$path")"
			cp -a "$REPO_DIR/$path" "$build_dir/recipe/extra/$(dirname "$path")/"
		done < "$recipe/extra.list"
	fi

	in_chroot chown -R builder:builder "/pkg-build/$name"

	# The recipe's own metadata comes from makepkg instead of being parsed
	# here: pkgname may be an array and makedepends is what has to be
	# installed before the build.
	srcinfo="$(in_chroot su -s /bin/bash builder -c \
		"cd /pkg-build/$name/recipe && makepkg --printsrcinfo")"
	pkgbase="$(awk -F' = ' '/^[[:space:]]*pkgbase = / { print $2; exit }' <<<"$srcinfo")"
	mapfile -t pkgnames < <(awk -F' = ' '/^[[:space:]]*pkgname = / { print $2 }' <<<"$srcinfo")
	mapfile -t makedepends < <(awk -F' = ' '/^[[:space:]]*makedepends = / { print $2 }' <<<"$srcinfo")
	[ -n "$pkgbase" ] || die "$name: makepkg --printsrcinfo reported no pkgbase"
	((${#pkgnames[@]})) || die "$name: makepkg --printsrcinfo reported no pkgname"

	# Rebuild only when the recipe changed and every package it produces is
	# still published. The kernel is an hour of work for nothing otherwise.
	stamp="$PLATFORM_REPO/.$pkgbase-stamp"
	have_all=1
	for p in "${pkgnames[@]}"; do
		compgen -G "$PLATFORM_REPO/$p-[0-9]*.pkg.tar.*" >/dev/null || have_all=0
	done
	hash="$( { recipe_hash "$recipe"
		for _p in ${extra_paths+"${extra_paths[@]}"}; do
			(cd "$REPO_DIR" && find "$_p" -type f -exec sha256sum {} +)
		done; } | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
	if ((have_all)) && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ]; then
		log "$pkgbase up to date (stamp $hash); nothing to build"
		continue
	fi

	# makedepends are installed here, as root, and the build then runs with
	# --nodeps: this chroot's builder is not in sudoers, so on a fresh chroot a
	# missing dependency could not be escalated by makepkg --syncdeps -- and it
	# has to be a loud pacman error, not a silent skip. Version constraints in
	# makedepends would need care; no recipe in this tree uses them.
	if ((${#makedepends[@]})); then
		log "Installing makedepends: ${makedepends[*]}"
		in_chroot pacman -S --noconfirm --needed "${makedepends[@]}"
	fi

	# --noextract once the work tree exists: re-extracting the tarball over it
	# would stamp the sources anew and restart the build. A recipe whose patch
	# text changed over such a tree fails loudly in prepare() rather than mixing
	# states, so delete $build_dir/recipe/src to start that recipe over.
	extract=""
	[ -d "$build_dir/recipe/src" ] && extract="--noextract"

	log "Building $pkgbase ($MAKEFLAGS)"
	in_chroot su -s /bin/bash builder -c "
		set -e
		export SRCDEST=/pkg-build/$name/src
		export PKGDEST=/pkg-build/$name/out
		export MAKEFLAGS='$MAKEFLAGS'
		cd /pkg-build/$name/recipe
		makepkg $extract -fc --nodeps --noconfirm --noprogressbar
	"

	shopt -s nullglob
	built=("$build_dir/out"/*.pkg.tar.*)
	shopt -u nullglob
	((${#built[@]})) || die "makepkg produced no packages for $pkgbase"
	# One version at a time in the bundle: drop what this build replaces.
	for p in "${pkgnames[@]}"; do
		rm -f "$PLATFORM_REPO/$p-"*.pkg.tar.*
	done
	cp "${built[@]}" "$PLATFORM_REPO/"
	printf '%s\n' "$hash" > "$stamp"
	log "Published $pkgbase into $PLATFORM_REPO"
	ls -1 "${built[@]}"
done

# Also covers a run where every recipe was skipped.
sign_platform_packages
# vim:set ts=8 sts=2 sw=2 et:
