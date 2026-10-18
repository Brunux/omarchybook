#!/bin/bash
# Build every asset of one release into a directory:
#
#   <device>.img             the disk image (scripts/make-image.sh) -- a build
#                            by-product: it is neither published nor listed in
#                            SHA256SUMS, only the .xz below is
#   <device>.img.xz          the same image, compressed for download
#   <device>-rootfs.tar.zst  the root filesystem as a tarball
#   <device>.vmlinuz.kpart   the kernel partition that matches the image
#   platform/                the [platform] bundle as a repository directory
#   RELEASE-INFO.txt         what this build was made of (commit, versions)
#   SHA256SUMS               hashes of the assets above
#
# Usage: make-release.sh [OUTDIR]    (default $WORK_DIR/release-<device>)
#
# The release notes are not generated here: they are written by hand, kept in
# docs/releases/ so they are versioned like everything else, and reused for the
# annotated tag and for whatever the release is published on.
#
# What is worth knowing about the assets:
#
#   * A release is built from a committed HEAD only (plan Phase 6). The working
#     tree is checked before anything is built, and ALLOW_DIRTY=yes is the
#     deliberate override for a rehearsal.
#   * Everything that is published is sanitized and asserted clean
#     (scripts/lib-dist.sh): a released image must not carry a Wi-Fi PSK, a host
#     key, a machine id or this repository's build root.
#   * The kpart embeds `root=UUID=...`, so it is the kernel partition of *this*
#     image and nothing else. It is shipped because it makes p1 reproducible from
#     the release alone; anyone writing their own card gets a kpart that matches
#     their own partitions from scripts/write-sd.sh or scripts/install-kpart.sh.
#   * platform/ is the [platform] bundle re-indexed as a repository: the signed
#     packages, their .sig, the database repo-add built during the image build
#     and the public key every image of this port already trusts. It is what
#     makes an update possible on a device without reflashing (plan Phase 6,
#     docs/recon.md 9); see its README.
#   * The build wants about 25 GiB of working disk, because three copies of the
#     system coexist (the rootfs, the image, and the staging copy lib-dist
#     sanitizes) before the compressed pair is written. With less, xz or zstd
#     dies with ENOSPC halfway through the build, and a full disk also stops
#     tooling that writes its own logs from saying why.
#   * The image and the tarball come out larger than 2 GiB, the biggest file a
#     GitHub release accepts, so releases publish them as <2 GiB parts
#     (`<name>.part-aa`, `.part-ab`, ...). SHA256SUMS hashes the whole file, so
#     reassembling the parts and checking them is what proves the download.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# shellcheck source=../boot/lib-cgpt.sh
. "$REPO_DIR/boot/lib-cgpt.sh"
# shellcheck source=lib-dist.sh
. "$(dirname "$0")/lib-dist.sh"

OUTDIR="${1:-$WORK_DIR/release-$DEVICE}"
IMAGE_SIZE_MIB="${IMAGE_SIZE_MIB:-}"
export IMAGE_SIZE_MIB

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" ROOTFS="$ROOTFS" \
		DEVICE="$DEVICE" IMAGE_SIZE_MIB="$IMAGE_SIZE_MIB" \
		BOOT_SIZE_MIB="$BOOT_SIZE_MIB" BOOT_FS="$BOOT_FS" KPART="$KPART" \
		ALLOW_DIRTY="${ALLOW_DIRTY:-}" ZSTD_LEVEL="${ZSTD_LEVEL:-}" XZ_LEVEL="${XZ_LEVEL:-}" \
		"$(readlink -f "$0")" "$OUTDIR"
fi

IMG="$OUTDIR/$DEVICE.img"
TARBALL="$OUTDIR/$DEVICE-rootfs.tar.zst"
KPART_OUT="$OUTDIR/$DEVICE.vmlinuz.kpart"
PLATFORM_OUT="$OUTDIR/platform"
STAGE="$WORK_DIR/release-stage-$DEVICE"

[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run scripts/build-rootfs.sh first)"

# A release has to say which commit it is. git may not be there (the build host
# is not the checkout's machine in every workflow), so a missing git is a
# warning and a dirty tree is an error.
COMMIT=""
TAG=""
DIRTY="unknown"
if command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
	# Both are read here, pinned to the same commit. Asking git for the tag at
	# the end of the build answered with a HEAD that had moved: a release built
	# from a tagged commit recorded `tag: none`, which is exactly the field a
	# reader uses to decide whether to trust the artifact.
	TAG="$(git -C "$REPO_DIR" describe --tags --exact-match "$COMMIT" 2>/dev/null || true)"
	if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
		DIRTY="yes"
		if [ "${ALLOW_DIRTY:-}" = "yes" ]; then
			warn "the working tree has uncommitted changes; building anyway (ALLOW_DIRTY=yes)"
		else
			die "the working tree has uncommitted changes: a release is built from a committed HEAD only (ALLOW_DIRTY=yes overrides)"
		fi
	else
		DIRTY="no"
	fi
else
	warn "no git checkout at $REPO_DIR: RELEASE-INFO.txt will not record a commit"
fi

mkdir -p "$OUTDIR"

log "1/5 Image"
"$REPO_DIR/scripts/make-image.sh" "$IMG" "$IMAGE_SIZE_MIB"

log "2/5 Compressing the image (xz -T0 -${XZ_LEVEL:-6})"
xz -T0 "-${XZ_LEVEL:-6}" -f -k "$IMG"

log "3/5 Root filesystem tarball"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# The same exclusion as the image: the profiles must not be copied and then
# deleted, or their bytes survive in the staging directory (scripts/lib-dist.sh).
EXCLUDES="$WORK_DIR/dist-excludes-$DEVICE.txt"
dist_write_excludes "$EXCLUDES"
rsync -aHAX --delete --exclude-from="$EXCLUDES" "$ROOTFS"/ "$STAGE"/
dist_sanitize "$STAGE"
dist_assert_clean "$STAGE"
dist_report_login_accounts "$STAGE"
dist_assert_no_profile_bytes "$STAGE"
# --acls/--xattrs keep what rsync -A/-X preserved, and --numeric-owner because
# the tarball is extracted as root, where the numbers are what count.
tar --acls --xattrs --xattrs-include='*' --numeric-owner -cpf - -C "$STAGE" . |
	zstd -T0 "-${ZSTD_LEVEL:-12}" -q -f -o "$TARBALL"
rm -rf "$STAGE"

log "4/5 kpart of the released image"
# Read the image's root UUID back instead of assuming it: the kpart must embed
# exactly the UUID the image boots with.
LOOP="$(losetup --show -f -P "$IMG")"
ROOT_UUID_IMG="$(blkid -s UUID -o value "${LOOP}p3" 2>/dev/null || true)"
losetup -d "$LOOP"
[ -n "$ROOT_UUID_IMG" ] || die "could not read the image's root UUID back from $IMG"
"$BOOT_DIR/make-kpart.sh" "$ROOTFS" "$KPART_OUT" "root=UUID=$ROOT_UUID_IMG rootwait rw"
kpart_verify "$KPART_OUT"

log "5/5 [platform] bundle as a repository"
# The database repo-add wrote while the image was built travels with the
# packages, so this directory can be served as-is (or re-indexed on a device).
rm -rf "$PLATFORM_OUT"
mkdir -p "$PLATFORM_OUT"
cp -a "$ROOTFS/packages/." "$PLATFORM_OUT/"
rm -f "$PLATFORM_OUT"/*.db.tar.gz.sig "$PLATFORM_OUT"/*.files.tar.gz.sig
cp "$PLATFORM_KEY_FILE" "$PLATFORM_OUT/platform.pub"
cat >"$PLATFORM_OUT/README.md" <<'EOF'
# [platform], the bundle this port builds

The packages Omarchy's own repositories cannot carry for this device: the kernel
(`linux-omarchy-book`), the platform layers (`omarchy-book`,
`omarchy-book-boot`), their `-dev` counterparts built from the pinned quattro
checkout, and `depthcharge-tools` (AUR only). Every package is signed with the
key in `platform.pub`, which is the public half of the key every image of this
port trusts (its private half never leaves the machine that built the image).

The database (`platform.db.tar.gz`) is not signed. Images of this port configure
pacman with `SigLevel = Required DatabaseOptional`, so a signed *package* is
required and a signed database is optional; that is why the package `.sig` files
matter and this note exists.

## Using it

On a machine that already runs this port, with the directory somewhere
reachable:

```sh
sudo pacman -U ./platform/<the package you want>
```

For updates through a repository, serve the directory and point the device at it
(one line under `[omarchy]` in `/etc/pacman.conf`):

```ini
[platform]
Server = https://example.invalid/omarchybook/platform
```

and refresh the database once (`sudo pacman -Sy`). Uncommenting a `[platform]`
section in the image instead is a build input: see `PLATFORM_REPO_URL` in
scripts/lib.sh.

A republished package -- same version, new bytes, because a recipe or the
vendored patch changed -- gets a `pkgrel` bump in its PKGBUILD before it is
released, or a machine that already has that version will not move to it
(docs/recon.md 9).
EOF
(
	cd "$PLATFORM_OUT"
	sha256sum platform.db.tar.gz platform.files.tar.gz platform.pub ./*.pkg.tar.* >SHA256SUMS
) || true

log "Recording what this release was built from"
{
	printf 'device:   %s\n' "$DEVICE"
	printf 'commit:   %s\n' "${COMMIT:-unknown}"
	printf 'dirty:    %s\n' "$DIRTY"
	printf 'tag:      %s\n' "${TAG:-none}"
	printf 'date:     %s\n' "$(date -Is)"
	printf 'channel:  %s\n' "$CHANNEL"
	printf 'kernel:   %s %s\n' "$KERNEL_PACKAGE" "$KERNEL_RELEASE"
	printf 'platform: %s\n' "$OMARCHY_PLATFORM"
	printf 'omarchy:  %s\n' "$OMARCHY_COMMIT"
	printf 'image:    %s MiB\n' "$(file_mib "$IMG")"
	printf 'kpart:    %s\n' "$KPART_OUT"
	printf 'root uuid:%s\n' "$ROOT_UUID_IMG"
	printf '\n[platform] bundle\n'
	(cd "$PLATFORM_OUT" && sha256sum ./*.pkg.tar.* | sed 's/^/  /')
	for _t in "$SRC_DIR"/ArchLinuxARM-aarch64-*.tar.gz; do
		[ -f "$_t" ] || continue
		printf '\nbootstrap tarball\n  %s  %s\n' "$(sha256sum "$_t" | cut -d' ' -f1)" "$(basename "$_t")"
	done
} >"$OUTDIR/RELEASE-INFO.txt"
sed 's/^/  /' "$OUTDIR/RELEASE-INFO.txt"

log "Checksums"
(
	cd "$OUTDIR"
	# Only what is published. The uncompressed image is a build by-product and
	# stays on the build machine, so listing it here made `sha256sum -c` fail
	# with a missing file for everyone who downloaded the release. Its hash is
	# the .xz's business: decompressing the .xz is what proves it.
	sha256sum "$(basename "$IMG").xz" "$(basename "$TARBALL")" \
		"$(basename "$KPART_OUT")" RELEASE-INFO.txt >SHA256SUMS
	cat SHA256SUMS
) | sed 's/^/  /'

log "Assets in $OUTDIR"
ls -lh "$OUTDIR" | sed 's/^/  /'
