#!/bin/bash
# Build the signed depthcharge FIT kernel partition image (kpart) for the device.
#
# Mirrors pmOS boot-deploy for ChromeOS devices:
#   depthchargectl build --root none --board <board> --kernel ... \
#       --kernel-cmdline ... --initramfs ... --fdtdir ... --compress ... -o ...
#
# Usage: make-kpart.sh [ROOTFS] [OUTPUT] [CMDLINE_EXTRA]
#
# Ported from debian-aarch64 (docs/plan.md §2.5). Differences from the Debian
# original: the kernel/initramfs names are the Arch ones (see scripts/lib.sh),
# and the vboot developer keys come from --keydir when the vendored copy exists
# (docs/plan.md §4).
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

[ -n "${1:-}" ] && ROOTFS="$1"
OUT="${2:-$KPART}"
CMDLINE_EXTRA="${3:-}"

KERNEL_IMG="$ROOTFS/$KERNEL_IMAGE_REL"
INITRD="$ROOTFS/$INITRAMFS_REL"
[ -f "$KERNEL_IMG" ] || die "kernel not found: $KERNEL_IMG"
[ -f "$INITRD" ] || die "initramfs not found: $INITRD"
[ -n "$DEPTHCHARGE_BOARD" ] || die "deviceinfo_depthcharge_board not set for $DEVICE"

# Stage the DTBs in a throwaway directory. It is deliberately not a fixed path:
# install-kpart.sh builds the kpart as root (it rewrites a partition), while
# build.sh does it as the invoking user, and a shared directory would be left
# root-owned and unremovable by the other side.
BUILDDIR="$(mktemp -d "$WORK_DIR/kpart-dtbs-$DEVICE.XXXXXX")"
DCT_TMP="$(mktemp -d "$WORK_DIR/dct-$DEVICE.XXXXXX")"
trap 'rm -rf "$BUILDDIR" "$DCT_TMP"' EXIT
# Same reason for the output: write-sd.sh and install-emmc.sh build the kpart as
# root, and depthchargectl cannot overwrite a root-owned file as brunux.
if [ -e "$OUT" ] && [ ! -w "$OUT" ]; then
	rm -f "$OUT" 2>/dev/null || sudo -n rm -f "$OUT" ||
		die "cannot replace $OUT (root-owned): remove it first"
fi
# Expand the deviceinfo_dtb glob (e.g. "mediatek/mt8192-asurada*").
# shellcheck disable=SC2086
set -- "$ROOTFS"/boot/dtbs/$DTB_GLOB.dtb
[ -e "$1" ] || die "no DTBs matching '$DTB_GLOB' under $ROOTFS/boot/dtbs"
cp "$@" "$BUILDDIR"/

# The vboot developer keys, when we carry them; otherwise depthchargectl searches
# its own defaults (/etc/depthcharge-tools, /usr/share/vboot/devkeys).
KEYARGS=()
if [ -d "$DEPTHCHARGE_KEYDIR" ]; then
	KEYARGS=(--keydir "$DEPTHCHARGE_KEYDIR")
	log "Using vboot keys from $DEPTHCHARGE_KEYDIR"
else
	warn "no keydir at $DEPTHCHARGE_KEYDIR; relying on depthchargectl's own key search"
fi

# depthchargectl/mkdepthcharge prepends "kern_guid=%U" itself (see
# --no-kern-guid), so it must NOT be added here.
CMDLINE="${KERNEL_CMDLINE}${CMDLINE_EXTRA}"
log "Building kpart (device=$DEVICE board=$DEPTHCHARGE_BOARD compression=$DEPTHCHARGE_COMPRESSION)"
log "  kernel : $KERNEL_IMG"
log "  initrd : $INITRD"
log "  dtbs   : $(ls "$BUILDDIR")"
log "  cmdline: $CMDLINE"

depthchargectl build --root none \
	--board "$DEPTHCHARGE_BOARD" \
	"${KEYARGS[@]}" \
	--kernel "$KERNEL_IMG" \
	--kernel-cmdline "$CMDLINE" \
	--initramfs "$INITRD" \
	--fdtdir "$BUILDDIR" \
	--compress "$DEPTHCHARGE_COMPRESSION" \
	--timestamp "${SOURCE_DATE_EPOCH:-$(date +%s)}" \
	--tmpdir "$DCT_TMP" \
	--output "$OUT"

log "Built $OUT ($(du -h "$OUT" | cut -f1))"
