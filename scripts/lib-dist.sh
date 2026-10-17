#!/bin/bash
# shellcheck shell=bash
# What a *published* artifact must not carry, shared by the two scripts that
# produce one (make-image.sh, make-release.sh).
#
# Sourced after scripts/lib.sh -- die()/log()/warn(), $ROOTFS, $WORK_DIR -- the
# way boot/lib-cgpt.sh is. Ported from debian-aarch64 (docs/plan.md 2.5, 4); the
# rule is the one Phase 6 exists for: never publish straight out of $ROOTFS.
#
# The build rootfs is a working system, and some of its state is the
# maintainer's rather than the port's:
#
#   * /etc/NetworkManager/system-connections/*.nmconnection holds a Wi-Fi PSK in
#     clear. Shipping one publishes somebody's Wi-Fi password.
#   * /var/lib/NetworkManager is the state NetworkManager built from them.
#   * /etc/ssh/ssh_host_* would make every installation share one host identity,
#     which stops identifying a machine at all.
#   * /etc/machine-id is the same problem for systemd, DHCP leases and journals.
#   * /home/*/.cache/omarchybook is this repository's own build root, and the
#     Wi-Fi profiles it would export live there too.
#
# and some of it is this repository's build state, which has no business in a
# released image:
#
#   * /packages is the local [platform] bundle copied in for the build. The
#     Omarchy post-install leaf rewrites /etc/pacman.conf without a [platform]
#     repository (docs/recon.md 8), so those packages are unreachable -- dead
#     weight, and it names this build host's paths.
#   * /var/cache/pacman/pkg is a bind mount of the persistent download cache
#     (scripts/lib.sh: $PACMAN_CACHE): several GiB of packages.
#   * /home/<name with no account> is what a tool that ran with the build host's
#     $HOME leaves behind -- `$HOME/.cache/omarchybook/...` recreated inside the
#     image, carrying the maintainer's user name.
#   * /tmp and /var/tmp carry runtime junk from the build (pulse's socket
#     directory, an omarchy lock file).
#   * /var/log/pacman.log and /var/log/omarchy-install.log are the build's own
#     transcripts, which describe this machine and this build.
#
# Two consequences shape this file, both measured on debian-aarch64's first
# release and worth repeating here:
#
# 1. Removing the state afterwards is NOT enough. Deleting a file inside an
#    image leaves its data in the filesystem's free blocks, and that is
#    measurable: their first release image had no *.nmconnection anywhere, `find`
#    over the mounted root found nothing, and `grep -a` over the .img still
#    printed both SSIDs and the PSK. So these paths are *excluded from the copy*
#    (DIST_EXCLUDES) and the finished artifact is searched for their contents
#    (dist_assert_no_profile_bytes), which is the check that would have caught it.
# 2. /etc/machine-id is left empty rather than absent: systemd-machine-id-setup
#    generates a fresh one on first boot. The SSH host keys are simply not copied
#    because the image ships sshdgenkeys.service (wants= by sshd.service), which
#    generates the ones it is missing.

# rsync patterns, anchored at the transfer root. The two logs are emptied rather
# than excluded (dist_sanitize), so the image still has them.
DIST_EXCLUDES='
/etc/NetworkManager/system-connections/
/var/lib/NetworkManager/
/etc/ssh/ssh_host_*
/etc/machine-id
/var/lib/dbus/machine-id
/root/.ssh/
/home/*/.cache/omarchybook/
/packages/
/var/cache/pacman/pkg/
/tmp/
/var/tmp/
/var/log/journal/
/var/log/private/
'

# Write the patterns where rsync can read them: rsync -aHAX --delete
# --exclude-from=<file> <rootfs>/ <destination>/
dist_write_excludes() {
	[ -n "${1:-}" ] || die "dist_write_excludes: no destination file given"
	printf '%s\n' "$DIST_EXCLUDES" | sed '/^$/d' >"$1"
}

# Empty a directory's contents without removing the directory itself (its mode
# and owner are part of the system). Handles dotfiles, which a plain `rm -rf
# "$d"/*` does not.
dist_empty_dir() {
	[ -d "$1" ] || return 0
	find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

# Remove a path only if it is there; keep "not there" from being an error.
dist_rm() {
	[ -e "$1" ] || [ -L "$1" ] || return 0
	rm -rf "$1"
}

# Empty a file that is part of a normal system, leaving it in place.
dist_truncate() {
	[ -e "$1" ] || return 0
	: >"$1"
}

# Make sure the state above is absent from a rootfs tree: an image mount, an
# extracted rootfs, a staging tree. Destructive by design -- it runs on a copy,
# never on $ROOTFS.
dist_sanitize() {
	_d="${1%/}"
	[ -d "$_d/etc" ] || die "dist_sanitize: $_d does not look like a root filesystem"

	log "Sanitizing $_d for publication"
	dist_rm "${_d:?}/etc/NetworkManager/system-connections"
	dist_rm "${_d:?}/var/lib/NetworkManager"
	# NetworkManager recreates both; leaving them (empty, 0700) gives an image
	# that looks like a normal system.
	install -d -m700 -o root -g root "$_d/etc/NetworkManager/system-connections"
	install -d -m700 -o root -g root "$_d/var/lib/NetworkManager"

	dist_rm "$_d"/etc/ssh/ssh_host_*
	: >"$_d/etc/machine-id"
	# /var/lib/dbus/machine-id is the same id, and on Arch it is a symlink to
	# /etc/machine-id. The copy excludes the path (DIST_EXCLUDES) so that a real
	# file -- the build host's id -- never arrives and its bytes never reach the
	# image's free blocks; the symlink is put back here so the result is what the
	# distribution ships.
	if [ -d "$_d/var/lib/dbus" ]; then
		dist_rm "$_d/var/lib/dbus/machine-id"
		ln -sfn /etc/machine-id "$_d/var/lib/dbus/machine-id"
	fi

	dist_rm "$_d/root/.ssh"
	dist_rm "$_d"/home/*/.cache/omarchybook
	for _h in "$_d"/home/*; do
		[ -d "$_h" ] || continue
		_n="${_h##*/}"
		grep -q "^$_n:" "$_d/etc/passwd" 2>/dev/null && continue
		warn "removing $_h: no account named '$_n' in the image"
		dist_rm "$_h"
	done

	dist_rm "$_d/packages"
	dist_empty_dir "$_d/var/cache/pacman/pkg"
	dist_empty_dir "$_d/tmp"
	dist_empty_dir "$_d/var/tmp"
	dist_empty_dir "$_d/var/log/journal"
	dist_empty_dir "$_d/var/log/private"
	dist_truncate "$_d/var/log/pacman.log"
	dist_truncate "$_d/var/log/omarchy-install.log"
}

# Refuse to publish <dir> if any of the state above is still in it, as files.
# This is the cheap check; dist_assert_no_profile_bytes is the one that looks at
# the bytes.
#
# Every finding goes on its own line: a refusal is useless if it does not say
# what it found. The Debian original concatenates them into one (measured while
# rehearsing this: six findings printed as one unbroken string).
_bad_add() {
	printf -v _bad '%s\n  %s' "$_bad" "$1"
}

dist_assert_clean() {
	_d="${1%/}"
	_bad=""

	# `|| true` on each find: with `set -o pipefail` a `head` that stops the pipe
	# early hands find a SIGPIPE (141), and a command substitution that fails takes
	# the whole script with it under `set -e` -- with the wrong message, since
	# finding "too many" bad files is exactly what the check is for. A missing
	# directory (a build that ships no sshd, a fake rootfs in a rehearsal) would do
	# the same.
	_found="$(find "$_d" -xdev \( -name '*.nmconnection' -o -name '*.lease' \) -print 2>/dev/null | head -5 || true)"
	[ -n "$_found" ] && _bad_add "$_found"
	_found="$(find "$_d/etc/ssh" -name 'ssh_host_*' -print 2>/dev/null | head -3 || true)"
	[ -n "$_found" ] && _bad_add "$_found"
	if [ -s "$_d/etc/machine-id" ]; then
		_bad_add "$_d/etc/machine-id (not empty)"
	fi
	if [ -e "$_d/var/lib/dbus/machine-id" ] && [ ! -L "$_d/var/lib/dbus/machine-id" ]; then
		_bad_add "$_d/var/lib/dbus/machine-id (a real file, not the symlink)"
	fi
	if find "$_d/root/.ssh" "$_d"/home/*/.cache/omarchybook -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
		_bad_add "$_d/root/.ssh or $_d/home/*/.cache/omarchybook (not empty)"
	fi
	if [ -e "$_d/packages" ]; then
		_bad_add "$_d/packages (the build-time [platform] bundle)"
	fi
	# The build's own transcripts: emptied, and present either way.
	for _l in "$_d/var/log/pacman.log" "$_d/var/log/omarchy-install.log"; do
		if [ -s "$_l" ]; then
			_bad_add "$_l (still the build's log)"
		fi
	done
	for _d2 in "$_d/tmp" "$_d/var/tmp" "$_d/var/cache/pacman/pkg"; do
		if find "$_d2" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
			_bad_add "$_d2 (not empty)"
		fi
	done
	for _h in "$_d"/home/*; do
		[ -d "$_h" ] || continue
		_n="${_h##*/}"
		grep -q "^$_n:" "$_d/etc/passwd" 2>/dev/null || _bad_add "$_h (no account named '$_n')"
	done

	if [ -n "$_bad" ]; then
		printf '%s\n' "$_bad" >&2
		die "refusing to publish: $_d still carries state that is not meant to leave this machine"
	fi
	log "Clean: no Wi-Fi profile, host key, machine id or build root in $_d"
}

# Report the accounts a released image still lets you log in as, without
# refusing: whether that is acceptable is the maintainer's call, not this
# script's, but a release should never carry one by accident.
#
# This exists because of ALARM's own `root` and `alarm` accounts -- uid 0 and
# uid 1000, in wheel, with the distribution's documented passwords -- and this
# port's own user, which the build creates with USERPASS (docs/plan.md Phase 6).
# All of them are deliberate; any of them is also a remote root if the machine is
# exposed before the password changes.
dist_report_login_accounts() {
	_d="${1%/}"
	[ -f "$_d/etc/shadow" ] || return 0
	_lucky=""
	while IFS=: read -r _n _pw _rest; do
		# "!" and "*" are a locked account; anything else is a password (or a
		# hash of one) that can be used.
		case "$_pw" in
		'!'* | '*' | '') continue ;;
		esac
		# /etc/shadow carries the hash but neither the uid nor the shell, and
		# reading them out of it by position reports the password-change date as
		# a uid -- /etc/passwd is where they live.
		_line="$(awk -F: -v n="$_n" '$1 == n { print $3 ":" $7 }' "$_d/etc/passwd" 2>/dev/null || true)"
		[ -n "$_line" ] || continue
		_lucky="$_lucky
  $_n (uid ${_line%%:*}, shell ${_line#*:})"
	done <"$_d/etc/shadow"

	if [ -n "$_lucky" ]; then
		warn "this artifact lets you log in to accounts that have a password set:$_lucky"
		warn "  change those passwords at first login, or lock the accounts before exposing the machine"
	fi
}

# Search the artifact itself -- an image file, a staging tree -- for the
# *contents* of the Wi-Fi profiles that were around the build: their SSIDs and
# their PSKs, one pattern per line.
#
# The patterns come from the build rootfs (where such profiles live) and from
# $WIFI_DIR (scripts/lib.sh: the exported copies the repository keeps outside
# itself). The artifact is not supposed to contain them at all, in a file or in
# the free blocks of a filesystem, which is why this check is byte-level.
dist_assert_no_profile_bytes() {
	_d="${1%/}"
	[ -e "$_d" ] || die "dist_assert_no_profile_bytes: $_d does not exist"
	# Profiles live in a 0700 root-only directory, so as an ordinary user the
	# glob below matches nothing and the check would pass without looking at
	# anything. Refuse the ambiguous case instead of trusting it.
	if [ -d "$ROOTFS/etc/NetworkManager/system-connections" ] &&
		! ls -A "$ROOTFS/etc/NetworkManager/system-connections" >/dev/null 2>&1; then
		die "dist_assert_no_profile_bytes: cannot read $ROOTFS/etc/NetworkManager/system-connections (run as root), so the check would be empty"
	fi
	_pat="$WORK_DIR/dist-profile-patterns.txt"
	: >"$_pat"
	for _dir in "$ROOTFS/etc/NetworkManager/system-connections" "$WIFI_DIR"; do
		for _p in "$_dir"/*.nmconnection; do
			[ -f "$_p" ] || continue
			basename "$_p" .nmconnection >>"$_pat"
			sed -n 's/^psk=//p' "$_p" >>"$_pat"
		done
	done
	sed -i '/^$/d' "$_pat"

	if [ ! -s "$_pat" ]; then
		log "No Wi-Fi profile in $ROOTFS or $WIFI_DIR: nothing to look for in $_d"
		rm -f "$_pat"
		return 0
	fi
	# -l: report the file that matched and stop, not the matching bytes (the
	# artifact is GiB of mostly zeros).
	_hits="$(grep -raF -l -f "$_pat" "$_d" 2>/dev/null | head -3 || true)"
	rm -f "$_pat"
	if [ -n "$_hits" ]; then
		printf '%s\n' "$_hits" | sed 's/^/  /' >&2
		die "$_d still contains Wi-Fi credentials: deleting a profile after copying it leaves its bytes in the image"
	fi
	log "Byte-checked: no SSID and no PSK anywhere in $_d"
}
