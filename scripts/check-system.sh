#!/bin/bash
# Health report for a system built by this repository.
#
# Runs *on the target device*, not on the build host, so it is standalone: it
# does not source scripts/lib.sh, it needs no repository and it changes nothing.
# Every check maps to a failure this port has actually hit, to a decision in
# docs/plan.md, or to something Omarchy's own code depends on, so a red line here
# is a regression, not a hypothetical.
#
# The report is only as good as the system it reads. Inside a chroot over a
# mounted image, /proc, /sys and dmesg describe the *host*, dmesg needs root, and
# `systemctl is-active` answers for the host too, so the checks that read live
# state stand down and say so instead of lying. The same is true before PID 1 is
# systemd. Package, file and configuration checks work anywhere.
#
# Usage:
#   scripts/check-system.sh [REPO_DIR]
#
# Run it as the desktop user: the session checks talk to that user's systemd and
# PipeWire, and the privileged reads (dmesg, pacman-key, NetworkManager profiles)
# go through passwordless `sudo -n`. From a root shell it re-executes itself as
# the session user when it can find one.
#
# With a repository checkout (REPO_DIR, default: the parent of this script) it
# also verifies that every package the manifests declare -- packages/*.list and
# devices/*/packages.list, with packages/aarch64-filter.list applied the way
# scripts/build-rootfs.sh applies it -- is installed.
set -uo pipefail

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_OK=0 _WARN=0 _FAIL=0 _SKIP=0

ok() { _OK=$((_OK + 1)); printf '  ok    %s\n' "$1"; }
warn() { _WARN=$((_WARN + 1)); printf '  warn  %s\n' "$1"; }
fail() { _FAIL=$((_FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { _SKIP=$((_SKIP + 1)); printf '  skip  %s\n' "$1"; }
info() { printf '  --    %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }
die() { printf 'check-system: %s\n' "$*" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
# pacman matches -Q targets as patterns, so `pacman -Qq linux-omarchy` happily
# answers with linux-omarchy-book: both of these compare exact names against the
# local package list instead (read once, in _ALL_PKGS).
_ALL_PKGS=""
pkgver() { pacman -Q 2>/dev/null | awk -v n="$1" '$1 == n { print $2; exit }'; }
pkghas() {
	case $'\n'"$_ALL_PKGS"$'\n' in
		*$'\n'"$1"$'\n'*) return 0 ;;
		*) return 1 ;;
	esac
}

# First field of a KEY=value file, without the quoting. Reads /etc/os-release,
# /var/lib/omarchy/image/target and the like.
keyval() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); gsub(/"/, ""); print; exit }' "$1" 2>/dev/null; }

# Everything of $1 matching the extended regex $2, at most $3 lines (default 3).
# Used instead of `grep -q` on a pipe: a reader that exits early closes the pipe
# on the writer, and with pipefail that reads as a failure (docs/recon.md §12).
matching() {
	printf '%s\n' "$1" | awk -v re="$2" -v max="${3:-3}" '$0 ~ re { print; if (++n >= max) exit }'
}
# Same, but 1 when there was at least one match.
has_match() { [ -n "$(matching "$1" "$2" 1)" ]; }

# First line of a command's output, or the empty string.
firstline() { "$@" 2>/dev/null | awk 'NR == 1 { print; exit }'; }

# ---------------------------------------------------------------------------
# Where we are running
# ---------------------------------------------------------------------------
# A chroot is detected the same way the boot chain does it (boot/lib-cgpt.sh):
# /proc/1/root is only the same filesystem as / when we *are* the top of the
# tree. Only a booted system may be described, so every live section is gated.
IN_CHROOT=0
if [ -e /proc/1/root ]; then
	_a="$(stat -Lc %d:%i / 2>/dev/null || true)"
	_b="$(stat -Lc %d:%i /proc/1/root/ 2>/dev/null || true)"
	if [ -z "$_a" ] || [ "$_a" != "$_b" ]; then
		IN_CHROOT=1
	fi
fi
if [ "$(firstline cat /proc/1/comm)" != systemd ]; then
	IN_CHROOT=1
fi
live() { [ "$IN_CHROOT" = 0 ] && [ -d /run/systemd/system ]; }

# A session of its own (systemd --user, a Wayland display and the compositor's
# socket) is what the session checks need; without it they report -- instead of
# guessing from a TTY or an SSH login.
in_session() {
	live || return 1
	[ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || return 1
	[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 1
	systemctl --user list-units >/dev/null 2>&1
}

SUDO=""
if [ "$(id -u)" -eq 0 ]; then
	_u="${CHECK_SYSTEM_USER:-${SUDO_USER:-}}"
	if [ -z "$_u" ] || [ "$_u" = root ]; then
		_u="$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF >= 3 { print $3 }' | sort -u | awk '$1 != "root" { print; exit }')"
	fi
	if [ -n "$_u" ] && [ "$_u" != root ] && id "$_u" >/dev/null 2>&1; then
		exec runuser -u "$_u" -- env CHECK_SYSTEM_USER="$_u" "$0" "$@"
	fi
	warn "running as root with no session user found: the audio and user-unit checks cannot run"
else
	SUDO="sudo -n"
fi
USER_NAME="$(id -un)"

REPO="${1:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)}"

# dmesg once, for every section that reads it (Firmware fills it when live).
_dm=""
# The local package list, for pkghas() and the declared-package check.
if command -v pacman >/dev/null 2>&1; then
	_ALL_PKGS="$(pacman -Qq 2>/dev/null || true)"
fi

printf 'check-system: %s on %s (as %s)\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$(uname -r)" "$USER_NAME"
if [ "$IN_CHROOT" = 1 ]; then
	warn "this looks like a chroot or an early boot: /proc, /sys and dmesg describe the host, so the live sections below are skipped"
fi

# ---------------------------------------------------------------------------
# System
# ---------------------------------------------------------------------------
section "System"
if [ -r /etc/os-release ]; then
	_os_name="$(keyval /etc/os-release NAME)"
	info "$_os_name $(keyval /etc/os-release VERSION_ID)"
	# An image built by this repository is Omarchy over Arch Linux ARM: Omarchy's
	# own install writes /etc/os-release with ID=omarchy and ID_LIKE=arch, so the
	# architecture is what has to be checked, not the distributor's name.
	case "$(keyval /etc/os-release ID_LIKE)" in
		*arch*) ok "os-release is Omarchy on Arch Linux ARM (ID=$(keyval /etc/os-release ID), ID_LIKE=arch)" ;;
		*)
			case "$(keyval /etc/os-release ID)" in
				arch | archarm) ok "os-release is $(_os_name)" ;;
				*) fail "os-release is $(_os_name) (ID=$(keyval /etc/os-release ID), ID_LIKE=$(keyval /etc/os-release ID_LIKE)): not an Arch Linux ARM system" ;;
			esac
			;;
	esac
else
	fail "/etc/os-release is missing"
fi
info "hostname $(cat /etc/hostname 2>/dev/null || echo '?')"
if have pacman; then
	_kver="$(pkgver linux-omarchy-book)"
	if [ -z "$_kver" ]; then
		fail "linux-omarchy-book is not installed"
	elif live; then
		ok "linux-omarchy-book $_kver is installed"
		case "$(uname -r)" in
			"${_kver%%-*}"*) ok "the running kernel is the installed one ($(uname -r))" ;;
			*) fail "running $(uname -r) but linux-omarchy-book is $_kver: /boot moved on and the kernel partition did not (boot/install-kpart.sh)" ;;
		esac
		case "$(uname -r)" in
			*-mt81) ok "the running kernel is this port's build" ;;
			*) fail "the running kernel $(uname -r) is not the -mt81 build: another kernel is in use" ;;
		esac
		if [ -d "/usr/lib/modules/$(uname -r)" ]; then
			ok "modules for the running kernel are installed"
		else
			fail "there is no /usr/lib/modules/$(uname -r): the running kernel has no modules"
		fi
	elif [ "$IN_CHROOT" = 1 ]; then
		ok "linux-omarchy-book $_kver is installed"
		skip "running kernel: uname describes the host here"
	fi
	if pkghas linux-omarchy; then
		fail "linux-omarchy (the upstream kernel package) is installed; the image must not carry it"
	else
		ok "linux-omarchy is absent"
	fi
	if pkghas linux-omarchy-book-headers; then
		info "linux-omarchy-book-headers is installed (DKMS builds need it; the image does not)"
	fi
else
	fail "pacman is missing: this is not the system this repository builds"
fi

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
section "Platform"
# The one answer the whole platform layer hangs on: a google,<board> device tree
# must come back as this family, not as plain aarch64 (docs/plan.md §6).
if have omarchy-hw-platform; then
	_plat="$(firstline omarchy-hw-platform)"
	case "$_plat" in
		aarch64-google) ok "omarchy-hw-platform answers aarch64-google" ;;
		"") fail "omarchy-hw-platform printed nothing" ;;
		*) fail "omarchy-hw-platform answers '$_plat', expected aarch64-google (the vendored patch teaches it google,<board>)" ;;
	esac
else
	fail "omarchy-hw-platform is missing (package omarchy-dev)"
fi
if live && [ -r /proc/device-tree/compatible ]; then
	_compat="$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ')"
	info "compatible: $_compat"
	case "$_compat" in
		*google,*) ok "the device tree names a google,<board> machine" ;;
		*) fail "the device tree has no google,<board>: this is not the machine this port is for" ;;
	esac
	[ -r /proc/device-tree/model ] && info "model: $(tr -d '\0' </proc/device-tree/model)"
else
	skip "device tree: /proc/device-tree needs a booted system"
fi
# The manifest an image build leaves behind (omarchy install/helpers/image-target.sh):
# until the first boot retires it, the system believes it is still being built.
_img=/var/lib/omarchy/image
if [ -d "$_img" ]; then
	if [ -f "$_img/target" ]; then
		warn "$_img/target is still there (platform=$(keyval "$_img/target" platform)): the first boot has not run the deferred hardware setup"
	elif [ -f "$_img/target.booted" ]; then
		ok "the image manifest was retired on first boot"
	fi
	[ -f "$_img/deferred-steps" ] && warn "$_img/deferred-steps is still queued: first-boot provisioning did not finish"
	[ -f "$_img/pacman-keyring" ] && warn "$_img/pacman-keyring is still queued: the image keyring was not made on first boot"
	[ -f "$_img/initramfs-inputs" ] && info "$_img/initramfs-inputs is present: the initramfs baseline still has to be recorded"
	[ -f "$_img/boot-rebuild" ] && warn "$_img/boot-rebuild is pending: the kernel partition has to be rewritten (boot/install-kpart.sh)"
else
	info "no $_img: this is not an image build"
fi
# [platform] is signed with the build key, and the image trusts it by lsign. An
# image's own keyring is made on first boot, so this is the check that says
# whether the kernel and the platform packages can still be verified.
if have pacman-key; then
	_keys="$($SUDO pacman-key --list-keys 2>/dev/null || true)"
	case "$_keys" in
		*"Omarchy Book Build"*) ok "the [platform] signing key is trusted" ;;
		*) fail "the [platform] signing key is not trusted: nothing from [platform] (the kernel included) can be verified; re-add it with pacman-key --add/platform.pub and --lsign-key" ;;
	esac
fi
if [ -f /usr/lib/systemd/journald.conf.d/10-omarchy-google.conf ]; then
	ok "the omarchy-google journald drop-in is installed (the journal is capped)"
else
	warn "the omarchy-google journald drop-in is missing"
fi

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------
section "Firmware"
if ! live; then
	skip "firmware: what the kernel loaded can only be read from dmesg on a booted system"
else
	_dm="$($SUDO dmesg 2>/dev/null || dmesg 2>/dev/null || true)"
	if [ -z "$_dm" ]; then
		skip "dmesg is not readable (passwordless sudo is needed for this one check)"
	else
		_bad="$(matching "$_dm" 'Direct firmware load.*failed' 3)"
		if [ -n "$_bad" ]; then
			fail "a firmware file did not load, so the device it belongs to is dead: $(printf '%s' "$_bad" | tr '\n' '|')"
		else
			ok "every firmware file the kernel asked for was loaded"
		fi
		case "$(matching "$_dm" 'media|mt8192' 1)" in
			"") warn "no MediaTek firmware line in dmesg" ;;
			*) ok "MediaTek firmware is in the log" ;;
		esac
		if has_match "$_dm" 'scp.*firmware|mtk-scp|scp_loader'; then
			ok "the MT8192 SCP firmware loaded (its boot noise is expected, AGENTS.md)"
		else
			info "no SCP firmware line in dmesg"
		fi
		case "$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ')" in
			*google,*) ok "cros_ec is in the tree as a google device" ;;
		esac
	fi
fi
for _d in /lib/firmware/mediatek /lib/firmware/rtw88 /lib/firmware/rtw89; do
	if [ -d "$_d" ]; then
		ok "firmware directory $_d"
	else
		info "no $_d"
	fi
done

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
section "Storage"
if ! live; then
	skip "storage: the layout and the UUIDs can only be compared on a booted system"
else
	_root_src="$(firstline findmnt -n -o SOURCE /)"
	_root_uuid="$(firstline findmnt -n -o UUID /)"
	_fstab_root="$(awk '$2 == "/" && $1 !~ /^[[:space:]]*#/ { print $1; exit }' /etc/fstab 2>/dev/null)"
	if [ -z "$_fstab_root" ]; then
		fail "/etc/fstab has no / entry"
	elif [ "$_fstab_root" = "UUID=$_root_uuid" ]; then
		ok "/etc/fstab's / UUID matches the running root ($_root_uuid)"
	else
		fail "/etc/fstab says / is $_fstab_root but the running root is UUID=$_root_uuid"
	fi
	_fstab_boot="$(awk '$2 == "/boot" && $1 !~ /^[[:space:]]*#/ { print $1; exit }' /etc/fstab 2>/dev/null)"
	if [ -n "$_fstab_boot" ]; then
		case "$_fstab_boot" in
			UUID=*) ok "/etc/fstab names /boot by UUID ($_fstab_boot)" ;;
			*) warn "/etc/fstab names /boot as $_fstab_boot; the port writes UUIDs" ;;
		esac
	fi
	case "$(firstline findmnt -n -o OPTIONS /)" in
		rw,*|*,rw|*,rw,*) ok "/ is mounted read-write" ;;
		*) fail "/ is not mounted read-write: the kernel or a filesystem error remounted it" ;;
	esac
	if command -v cgpt >/dev/null 2>&1; then
		_disk="/dev/$(firstline lsblk -no PKNAME "$_root_src")"
		if [ -b "$_disk" ]; then
			_gpt="$($SUDO cgpt show "$_disk" 2>/dev/null || true)"
			for _label in pmOS_kernel pmOS_boot pmOS_root; do
				case "$_gpt" in
					*"\"$_label\""*) ok "GPT carries $_label" ;;
					*) fail "GPT has no $_label label on $_disk" ;;
				esac
			done
			case "$_gpt" in
				*"ChromeOS kernel"*) ok "the kernel partition has ChromeOS kernel type" ;;
				*) fail "no ChromeOS kernel type in the GPT: depthcharge cannot boot this disk" ;;
			esac
			case "$_gpt" in
				*priority=1*) ok "the kernel partition is successful and priority 1" ;;
				*) warn "the kernel partition is not marked priority=1: the firmware may fall back" ;;
			esac
			case "$_root_src" in
				"$_disk"p3) ok "the running root is $_disk p3" ;;
				*) warn "the running root is $_root_src, not ${_disk}p3" ;;
			esac
		else
			info "cannot resolve the disk behind $_root_src"
		fi
	else
		warn "cgpt is missing (vboot-utils): the GPT layout cannot be checked"
	fi
	_use="$(awk 'NR == 2 { gsub(/%/, "", $5); print $5 }' <<<"$(df -P / 2>/dev/null)")"
	case "$_use" in
		'' | *[!0-9]*) ;;
		*)
			if [ "$_use" -ge 90 ]; then
				warn "the root filesystem is $_use% full"
			else
				ok "the root filesystem is $_use% full"
			fi
			;;
	esac
	if [ -s /proc/swaps ]; then
		ok "swap is active: $(awk 'NR > 1 { printf "%s ", $1 }' /proc/swaps)"
		if has_match "$(cat /proc/swaps)" '/dev/zram0'; then
			ok "swap is on zram as zram-generator intends"
		else
			warn "swap is not on zram; zram-generator's unit may not have run"
		fi
	else
		fail "no swap at all: systemd-zram-setup@zram0.service should have made it (zram-generator)"
	fi
	_fs_err="$(matching "$_dm" 'ext4-fs error|EXT4-fs \(.*\): error|remounting filesystem read-only' 3)"
	if [ -n "$_fs_err" ]; then
		fail "filesystem errors in dmesg: $(printf '%s' "$_fs_err" | tr '\n' '|')"
	else
		ok "no filesystem errors in dmesg"
	fi
fi

# ---------------------------------------------------------------------------
# Display and GPU
# ---------------------------------------------------------------------------
section "Display and GPU"
if ! live; then
	skip "display and GPU: /sys and dmesg can only be read on a booted system"
else
	_conns=""
	for _c in /sys/class/drm/card*-*/status; do
		[ -r "$_c" ] || continue
		case "$(cat "$_c" 2>/dev/null)" in
			connected) _conns="$_conns $(basename "$(dirname "$_c")")" ;;
		esac
	done
	if [ -n "$_conns" ]; then
		ok "connected DRM outputs:$_conns"
	else
		fail "no DRM output is connected: the panel never came up"
	fi
	if [ -d /sys/module/panfrost ]; then
		ok "panfrost is loaded (Mesa on the Mali GPU)"
	else
		fail "panfrost is not loaded: Hyprland would fall back to software rendering"
	fi
	if has_match "$_dm" 'panfrost.*(Mali|mali)'; then
		ok "panfrost bound the Mali GPU: $(firstline matching "$_dm" 'panfrost.*(Mali|mali)' 1)"
	elif [ -n "$_dm" ]; then
		warn "no panfrost binding line in dmesg"
	fi
	if in_session; then
		_hv="$(hyprctl -j version 2>/dev/null || true)"
		_hm="$(hyprctl -j monitors 2>/dev/null || true)"
		if [ -n "$_hv" ]; then
			ok "Hyprland is running: $(firstline hyprctl version | sed 's/^Hyprland, built from branch //')"
		else
			fail "HYPRLAND_INSTANCE_SIGNATURE is set but hyprctl does not answer"
		fi
		case "$_hm" in
			'[]' | '') fail "hyprctl reports no monitor: the session has no output" ;;
			'['*) ok "$(printf '%s' "$_hm" | awk '{ n = gsub(/\"name\":/, "", $0) } END { print n " monitor(s) in the session" }')" ;;
			*) info "hyprctl monitors: $(printf '%s' "$_hm" | tr -d '\n')" ;;
		esac
		_cerr="$(hyprctl configerrors 2>/dev/null || true)"
		if [ -z "$_cerr" ]; then
			ok "hyprctl reports no configuration errors"
		else
			fail "the Hyprland configuration has errors: $(printf '%s' "$_cerr" | awk 'NR == 1')"
		fi
	else
		skip "the running session: start this from the desktop session, not a TTY"
	fi
	if have brightnessctl; then
		ok "brightnessctl is installed"
	else
		fail "brightnessctl is missing: the brightness keys cannot work"
	fi
	if [ -f /usr/lib/udev/rules.d/90-brightnessctl.rules ]; then
		ok "the backlight udev rule is installed (group video, group-writable)"
	else
		fail "the backlight udev rule is missing: brightnessctl will be denied"
	fi
	_bl=""
	for _b in /sys/class/backlight/*/brightness; do
		[ -e "$_b" ] || continue
		_bl="$_b"
		_mode="$(stat -c %a "$_b" 2>/dev/null || true)"
		_grp="$(stat -c %G "$_b" 2>/dev/null || true)"
		if [ "$_grp" = video ] && [ "${_mode: -2:1}" -ge 6 ] 2>/dev/null; then
			ok "backlight is writable by group video ($_mode $_grp $_b)"
		else
			fail "$_b is $_mode $_grp: brightnessctl will fail with permission denied"
		fi
	done
	[ -n "$_bl" ] || fail "no backlight device in /sys/class/backlight"
	if [ "$(id -u)" -ne 0 ]; then
		case " $(id -nG 2>/dev/null || true) " in
			*' video '*) ok "the session user is in group video" ;;
			*) fail "the session user is not in group video: brightnessctl cannot write the backlight" ;;
		esac
	fi
fi

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
section "Input"
if ! live; then
	skip "input: /proc/bus/input/devices and keyd only describe a booted system"
else
	if [ -r /proc/bus/input/devices ]; then
		_kb="$(awk '/^H: Handlers=.*kbd/ { n++ } END { print n + 0 }' /proc/bus/input/devices)"
		_pt="$(awk '/^H: Handlers=.*(mouse|event)/ { n++ } END { print n + 0 }' /proc/bus/input/devices)"
		if [ "$_kb" -ge 1 ]; then
			ok "$_kb input device(s) report a keyboard handler"
		else
			fail "no input device reports a keyboard handler: the internal keyboard is dead"
		fi
		[ "$_pt" -ge 1 ] && ok "$_pt input device(s) report a pointer or event handler" ||
			fail "no input device reports a pointer handler: the touchpad is dead"
	else
		fail "/proc/bus/input/devices is unreadable"
	fi
	if have keyd; then
		_conf=/etc/keyd/default.conf
		_kconf="$(cat "$_conf" 2>/dev/null || true)"
		if [ -z "$_kconf" ]; then
			fail "$_conf is missing: the top-row action keys cannot be reached"
		else
			for _x in '-0000:0000:c68a2d8e' '-0000:0000:3c5e67dc'; do
				case "$_kconf" in
					*"$_x"*) ok "keyd excludes $_x (the power button and the headset jack stay out of its hands)" ;;
					*) fail "keyd no longer excludes $_x: it would grab the power button or the headset jack" ;;
				esac
			done
			if has_match "$_kconf" '^[[:space:]]*sleep[[:space:]]*='; then
				fail "keyd maps the Lock key (KEY_SLEEP): it would stop suspending on that key"
			else
				ok "keyd leaves the Lock key (KEY_SLEEP) alone"
			fi
		fi
		if systemctl is-active --quiet keyd 2>/dev/null; then
			ok "keyd is active"
		else
			fail "keyd is not active: no F-keys and no remapped top row"
		fi
		_klog="$($SUDO journalctl -b -u keyd --no-pager 2>/dev/null || true)"
		if has_match "$_klog" 'matched|device added'; then
			ok "keyd matched a device: $(firstline matching "$_klog" 'matched|device added' 1)"
		else
			warn "keyd's log for this boot says nothing about a matched device"
		fi
	else
		fail "keyd is missing"
	fi
	_hsk="$(firstline systemctl show -p HandleSuspendKey --value)"
	info "logind HandleSuspendKey: ${_hsk:-suspend (default)}"
fi

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------
section "Audio"
# Omarchy drives the desktop through the PulseAudio protocol: pactl sets the
# volume, lists the tuning sinks and finds the monitor source for screen
# recording, while wpctl is what the PipeWire side answers to. Both have to
# work, and both packages have to be installed for that (packages/omarchy.list).
for _p in pipewire wireplumber pipewire-alsa pipewire-audio pipewire-pulse alsa-utils alsa-ucm-conf; do
	if pkghas "$_p"; then
		ok "package $_p"
	else
		fail "package $_p is missing"
	fi
done
if [ -d /usr/share/alsa/ucm2/MediaTek/mt8192 ]; then
	ok "the MT8192 UCM configuration is installed"
else
	fail "alsa-ucm-conf has no MediaTek/mt8192: the codec cannot take its boot sequence"
fi
if ! live; then
	skip "the sound card and PipeWire can only be read on a booted system"
else
	if have wpctl; then
		_ws="$(wpctl status 2>/dev/null || true)"
		if has_match "$_ws" 'Sinks:'; then
			ok "WirePlumber answers wpctl"
		else
			fail "wpctl gets no answer: wireplumber is not running for this user"
		fi
	else
		fail "wpctl is missing"
	fi
	if have pactl; then
		_pi="$(pactl info 2>/dev/null || true)"
		if [ -n "$_pi" ]; then
			ok "the PulseAudio protocol server answers: $(firstline matching "$_pi" 'Server Name' 1)"
		else
			fail "pactl gets no server: pipewire-pulse is not installed or not running, and Omarchy's volume keys, audio OSD and recording-with-sound all use it"
		fi
		_cards="$(pactl list cards short 2>/dev/null || true)"
		if has_match "$_cards" 'alsa_card'; then
			ok "the sound card is a Pulse card: $(printf '%s' "$_cards" | awk 'NR == 1 { print $2 }')"
		else
			fail "no card: the MT8192 codec did not come up"
		fi
		_prof="$(pactl list cards 2>/dev/null | awk -F': ' '/Active Profile/ { print $2; exit }')"
		case "$_prof" in
			off) fail "the card's active profile is off: no audio at all (the UCM profile did not come up)" ;;
			'') warn "could not read the card's active profile" ;;
			*) ok "the card's active profile is $_prof" ;;
		esac
		_sinks="$(pactl list short sinks 2>/dev/null || true)"
		if [ -z "$_sinks" ]; then
			fail "no sink: nothing can play"
		elif has_match "$_sinks" 'Dummy'; then
			fail "the only sink is a Dummy Output: the real speaker is not there"
		else
			ok "sinks: $(printf '%s' "$_sinks" | awk '{ printf "%s ", $2 }')"
		fi
		_srcs="$(pactl list short sources 2>/dev/null || true)"
		if has_match "$_srcs" 'monitor'; then
			ok "a monitor source exists for recording with sound"
		else
			warn "no monitor source: screen recording with audio will have no sound"
		fi
	else
		fail "pactl is missing (package libpulse)"
	fi
	if [ -r /proc/asound/cards ]; then
		if has_match "$(cat /proc/asound/cards)" 'MT8192|mt8192'; then
			ok "ALSA sees the MT8192 card"
		else
			fail "ALSA does not list an MT8192 card: $(awk 'NR > 1 { print; exit }' /proc/asound/cards)"
		fi
	fi
	if [ "$(id -u)" -ne 0 ] && ! systemctl --user is-active --quiet pipewire 2>/dev/null; then
		warn "pipewire is not active for this user"
	fi
fi

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
section "Network"
for _p in networkmanager wpa_supplicant iw wireless-regdb; do
	if pkghas "$_p"; then
		ok "package $_p"
	else
		fail "package $_p is missing"
	fi
done
if ! live; then
	skip "Wi-Fi and NetworkManager can only be read on a booted system"
else
	_ifaces="$(iw dev 2>/dev/null | awk '$1 == "Interface" { printf "%s ", $2 }' || true)"
	case "$_ifaces" in
		*'wl'*) ok "Wi-Fi interfaces: $_ifaces" ;;
		'') fail "iw lists no wireless interface: the Wi-Fi firmware or driver did not come up" ;;
		*) warn "iw lists only $_ifaces, none of them wireless" ;;
	esac
	_reg="$(iw reg get 2>/dev/null | awk -F': ' '/country/ { print $2; exit }' || true)"
	case "$_reg" in
		'' | '00') warn "the regulatory domain is not set (${_reg:-unknown}): the world domain limits the Wi-Fi" ;;
		*) ok "regulatory domain $_reg" ;;
	esac
	if systemctl is-active --quiet NetworkManager 2>/dev/null; then
		ok "NetworkManager is active"
		_devs="$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null || true)"
		if has_match "$_devs" 'wifi'; then
			if has_match "$_devs" ':unmanaged$'; then
				fail "NetworkManager leaves a device unmanaged: $(firstline matching "$_devs" ':unmanaged$' 1)"
			else
				ok "NetworkManager manages a Wi-Fi device: $(firstline matching "$_devs" 'wifi' 1)"
			fi
		else
			fail "NetworkManager sees no Wi-Fi device"
		fi
		_conns_n="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: 'NF > 1 { n++ } END { print n + 0 }')"
		if [ "$_conns_n" -gt 0 ]; then
			ok "$_conns_n NetworkManager connection profile(s)"
		else
			warn "no connection profile: the image ships none, connect with nmtui (part of the networkmanager package)"
		fi
		_pinned="$($SUDO grep -rl 'interface-name' /etc/NetworkManager/system-connections/ 2>/dev/null || true)"
		case "$_pinned" in
			'') ok "no profile pins an interface name" ;;
			*) warn "a profile pins interface-name ($_pinned): a profile imported from another system pins wlan0, and the interface here is not wlan0" ;;
		esac
	else
		fail "NetworkManager is not active"
	fi
	if have nmtui; then ok "nmtui is available"; else warn "nmtui is missing"; fi
	if systemctl is-active --quiet sshd 2>/dev/null; then
		info "sshd is active"
	fi
	if systemctl is-active --quiet ufw 2>/dev/null; then
		ok "ufw is active"
	else
		warn "ufw is not active"
	fi
fi

# ---------------------------------------------------------------------------
# Bluetooth
# ---------------------------------------------------------------------------
section "Bluetooth"
if pkghas bluez-utils; then
	ok "bluez-utils is installed"
else
	fail "bluez-utils is missing: bluetoothctl is gone"
fi
if ! live; then
	skip "the Bluetooth controller can only be read on a booted system"
else
	_bh="$(bluetoothctl show 2>/dev/null || true)"
	if [ -z "$_bh" ]; then
		fail "bluetoothctl has no controller: the MediaTek Bluetooth firmware did not come up"
	else
		case "$_bh" in
			*"Powered: yes"*) ok "the Bluetooth controller is powered: $(firstline matching "$_bh" 'Name:' 1)" ;;
			*) fail "the Bluetooth controller is not powered (bluetoothctl show): $(firstline matching "$_bh" 'Powered' 1)" ;;
		esac
	fi
	_rf="$(rfkill list bluetooth 2>/dev/null || true)"
	case "$_rf" in
		*"Soft blocked: yes"*) warn "Bluetooth is soft-blocked by rfkill" ;;
		'') info "rfkill knows no Bluetooth device" ;;
		*) ok "Bluetooth is not soft-blocked" ;;
	esac
fi

# ---------------------------------------------------------------------------
# Suspend and power
# ---------------------------------------------------------------------------
section "Suspend and power"
if ! live; then
	skip "suspend: /sys/power and logind can only be read on a booted system"
else
	_pstate="$(cat /sys/power/state 2>/dev/null || true)"
	case "$_pstate" in
		*"mem"*) ok "system suspend is offered (/sys/power/state: $_pstate)" ;;
		'') warn "/sys/power/state is unreadable" ;;
		*) fail "/sys/power/state offers no mem: the machine cannot suspend" ;;
	esac
	_msleep="$(cat /sys/power/mem_sleep 2>/dev/null || true)"
	case "$_msleep" in
		*s2idle*) ok "s2idle is available: $(firstline matching "$_msleep" '\[' 1)" ;;
		'') info "no mem_sleep file" ;;
		*) fail "s2idle is not in mem_sleep ($_msleep): suspend will not work on this SoC" ;;
	esac
	for _u in systemd-logind polkit; do
		if systemctl is-active --quiet "$_u" 2>/dev/null; then
			ok "$_u is active"
		else
			fail "$_u is not active"
		fi
	done
	if pkghas power-profiles-daemon; then
		systemctl is-active --quiet power-profiles-daemon 2>/dev/null &&
			ok "power-profiles-daemon is active" ||
			warn "power-profiles-daemon is installed but not active"
	fi
	if [ -f /usr/lib/systemd/user/omarchy-sleep-lock.service ]; then
		ok "the Omarchy sleep lock unit is installed"
	else
		fail "omarchy-sleep-lock.service is missing: the session will not lock before suspending"
	fi
	if in_session; then
		if pgrep -x omarchy-system-sleep-monitor >/dev/null 2>&1; then
			ok "the sleep monitor is running in the session"
		else
			fail "omarchy-system-sleep-monitor is not running: the session will not lock on suspend"
		fi
	fi
	_susp="$(matching "$_dm" 'PM: suspend entry' 5)"
	if [ -n "$_susp" ]; then
		ok "suspend has been used this boot ($(printf '%s' "$_susp" | awk 'END { print NR }') cycle(s))"
		_res="$(matching "$_dm" 'PM: suspend exit|PM: resume' 1)"
		[ -n "$_res" ] && ok "the machine came back: $(printf '%s' "$_res")" ||
			warn "no resume line yet: the machine may be suspended right now"
	else
		info "no suspend cycle this boot"
	fi
fi

# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------
section "Clock"
_year="$(date +%Y 2>/dev/null || true)"
case "$_year" in
	'' ) info "cannot read the date" ;;
	202[5-9] | 20[3-9][0-9]) ok "the clock reads $(date +%Y-%m-%d\ %H:%M)" ;;
	*) warn "the clock reads $(date +%Y-%m-%d\ %H:%M): a wrong clock breaks TLS and updates (systemd-timesyncd is enabled in the image)" ;;
esac
if ! live; then
	skip "NTP state: timedatectl needs a booted system"
else
	if have timedatectl; then
		_ntp="$(firstline timedatectl show -p NTPSynchronized --value)"
		case "$_ntp" in
			yes) ok "the clock is synchronised" ;;
			*) warn "the clock is not synchronised yet (systemd-timesyncd is enabled and needs the network)" ;;
		esac
		info "timezone $(firstline timedatectl show -p Timezone --value)"
	fi
	if systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null; then
		ok "systemd-timesyncd is enabled"
	else
		warn "systemd-timesyncd is not enabled: the clock will never sync"
	fi
fi

# ---------------------------------------------------------------------------
# Session (the Omarchy desktop)
# ---------------------------------------------------------------------------
section "Session"
for _p in hyprland quickshell uwsm sddm; do
	if pkghas "$_p"; then
		ok "package $_p"
	else
		fail "package $_p is missing"
	fi
done
if [ -f /usr/share/wayland-sessions/hyprland-uwsm.desktop ]; then
	ok "the Hyprland (uwsm) session is installed"
else
	fail "hyprland-uwsm.desktop is missing: the greeter has no Omarchy session to offer"
fi
_lm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
case "$_lm" in
	*sddm.service) ok "display-manager.service points at sddm" ;;
	'') warn "display-manager.service is not linked: nothing brings up the login screen" ;;
	*) warn "display-manager.service points at $_lm, not sddm" ;;
esac
_sddm="$(cat /etc/sddm.conf.d/*.conf 2>/dev/null || true)"
case "$_sddm" in
	*"DisplayServer=wayland"*) ok "SDDM runs Wayland" ;;
	*) warn "SDDM is not configured for Wayland" ;;
esac
case "$_sddm" in
	*start-hyprland*) ok "SDDM's compositor command is installed ($(firstline matching "$_sddm" 'CompositorCommand' 1))" ;;
	*) fail "SDDM has no start-hyprland compositor command: the greeter cannot start the session" ;;
esac
if [ -d /usr/share/sddm/themes/omarchy ]; then
	ok "the Omarchy SDDM theme is installed"
else
	warn "the Omarchy SDDM theme is missing"
fi
if ! live; then
	skip "the running session: start this from the desktop session, not a TTY or a chroot"
else
	if in_session; then
		case "${XDG_CURRENT_DESKTOP:-}" in
			*Hyprland*) ok "this shell runs inside Hyprland (XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP)" ;;
			*) warn "XDG_CURRENT_DESKTOP is '${XDG_CURRENT_DESKTOP:-unset}' inside Hyprland" ;;
		esac
		if pgrep -x quickshell >/dev/null 2>&1 || pgrep -x qs >/dev/null 2>&1; then
			ok "the Quickshell shell is running"
		else
			fail "no quickshell process: the bar, the OSDs and the menus are not up"
		fi
		_cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
		if [ -d "$_cfg/hypr" ]; then
			ok "the user's Hyprland configuration exists ($_cfg/hypr)"
		else
			fail "$_cfg/hypr is missing: the user was never provisioned (omarchy-provision-user)"
		fi
		if systemctl --user is-active --quiet pipewire 2>/dev/null; then
			ok "pipewire is active in the session"
		fi
		if systemctl --user is-enabled --quiet omarchy-sleep-lock.service 2>/dev/null; then
			ok "omarchy-sleep-lock.service is enabled for this user"
		else
			warn "omarchy-sleep-lock.service is not enabled for this user"
		fi
	else
		skip "the running session: this is not a Wayland session shell (no HYPRLAND_INSTANCE_SIGNATURE)"
	fi
fi
if live; then
	if systemctl is-active --quiet sddm 2>/dev/null; then
		ok "sddm is active"
	else
		fail "sddm is not active: there is no login screen"
	fi
fi
if [ -f /var/lib/omarchy/provisioning/pending ]; then
	warn "/var/lib/omarchy/provisioning/pending is set: the owner setup will ask for the user on tty1 at boot"
fi
# Accounts with a password. The port keeps ALARM's `alarm` account on purpose and
# says so in the release notes (docs/plan.md §3, decision 8); this is the report
# the plan wanted against the device itself.
if [ -r /etc/shadow ]; then
	_pw="$(awk -F: '$2 !~ /^[!*]/ && $2 != "" { printf "%s ", $1 }' /etc/shadow 2>/dev/null || true)"
	case "$_pw" in
		'') ok "no account has a password" ;;
		*) warn "accounts with a password: $_pw (the release notes carry the checklist)" ;;
	esac
fi

# ---------------------------------------------------------------------------
# Fonts and icons
# ---------------------------------------------------------------------------
section "Fonts and icons"
# The families Omarchy's own configuration asks for: the Hyprland config and the
# shell use "JetBrainsMono Nerd Font" (and its Nerd Font glyphs for icons),
# "Noto Color Emoji" for emoji and the Noto CJK family for CJK text.
if have fc-list; then
	_fams="$(fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//' | sort -u || true)"
	for _f in "JetBrainsMono Nerd Font" "Noto Color Emoji" "Noto Sans CJK JP"; do
		case "$_fams" in
			*"$_f"*) ok "font: $_f" ;;
			*) fail "font missing: $_f (Omarchy's configuration asks for it)" ;;
		esac
	done
	info "$(printf '%s\n' "$_fams" | awk 'NF { n++ } END { print n + 0 }') font families are installed"
else
	fail "fontconfig (fc-list) is missing"
fi

# ---------------------------------------------------------------------------
# Update path
# ---------------------------------------------------------------------------
section "Update path"
_pconf="$(cat /etc/pacman.conf 2>/dev/null || true)"
if [ -z "$_pconf" ]; then
	fail "/etc/pacman.conf is unreadable"
else
	case "$_pconf" in
		*IgnorePkg*linux-omarchy-book*) ok "the kernel is pinned: 'omarchy update' cannot pull linux-omarchy back in" ;;
		*) fail "/etc/pacman.conf does not ignore linux-omarchy-book: an update would replace this port's kernel" ;;
	esac
	case "$_pconf" in
		*'[platform]'*)
			ok "the [platform] repository is configured"
			info "$(firstline matching "$_pconf" '^Server *=.*platform' 1)"
			;;
		*)
			info "no [platform] repository: the kernel and the platform packages are updated by reflashing (docs/plan.md §3, decision 7)"
			;;
	esac
	case "$_pconf" in
		*'[omarchy]'*) ok "the [omarchy] repository is configured" ;;
		*) warn "no [omarchy] repository: the Omarchy packages cannot be updated" ;;
	esac
fi
if have omarchy; then
	ok "the omarchy command is installed ($(cat /usr/share/omarchy/version 2>/dev/null || echo '?'))"
else
	fail "the omarchy command is missing"
fi

# ---------------------------------------------------------------------------
# Declared packages
# ---------------------------------------------------------------------------
section "Declared packages"
# With a checkout, every package the manifests declare has to be installed. The
# aarch64 filter is applied exactly as scripts/build-rootfs.sh applies it, so a
# package the port drops on purpose is not reported as missing.
filter_list() {
	local _filter="$REPO/packages/aarch64-filter.list" _line _name _d _i _kw _a _b
	local -a _drops=() _from=() _to=()
	if [ -f "$_filter" ]; then
		while read -r _kw _a _b; do
			case "${_kw:-}" in
				'' | '#'*) continue ;;
				drop) _drops+=("$_a") ;;
				replace) _from+=("$_a"); _to+=("${_b:-}") ;;
			esac
		done <"$_filter"
	fi
	while read -r _line; do
		_name="${_line%%#*}"
		_name="$(printf '%s' "$_name" | tr -d '[:space:]')"
		[ -n "$_name" ] || continue
		for _d in "${_drops[@]}"; do
			# shellcheck disable=SC2053
			[[ $_name == $_d ]] && continue 2
		done
		for _i in "${!_from[@]}"; do
			if [[ $_name == "${_from[_i]}" ]]; then
				_name="${_to[_i]}"
				break
			fi
		done
		printf '%s\n' "$_name"
	done
}
if [ -n "$REPO" ] && [ -d "$REPO/packages" ]; then
	_declared="$(for _l in "$REPO"/packages/*.list "$REPO"/devices/*/packages.list; do
		[ -f "$_l" ] || continue
		case "$_l" in */aarch64-filter.list) continue ;; esac
		cat "$_l"
	done | filter_list | awk '!seen[$0]++')"
	_missing=""
	_n=0
	while read -r _p; do
		[ -n "$_p" ] || continue
		_n=$((_n + 1))
		pkghas "$_p" || _missing="$_missing $_p"
	done <<<"$_declared"
	if [ -z "$_missing" ]; then
		ok "all $_n declared packages are installed"
	else
		fail "declared but not installed:$_missing"
	fi
else
	skip "no repository checkout at ${REPO:-<none>}: pass REPO_DIR to compare the manifests with the system"
fi

# ---------------------------------------------------------------------------
# Journal
# ---------------------------------------------------------------------------
section "Journal"
if ! live; then
	skip "journal: only a booted system has this boot's journal"
else
	_j="$(journalctl -b -p err --no-pager -o short 2>/dev/null || $SUDO journalctl -b -p err --no-pager -o short 2>/dev/null || true)"
	if [ -z "$_j" ]; then
		ok "the journal has no error-priority lines this boot"
	else
		for _pat in 'kernel BUG' 'Oops' 'general protection fault' 'segfault at' 'I/O error' 'Call trace'; do
			if has_match "$_j" "$_pat"; then
				fail "the journal shows '$_pat': $(firstline matching "$_j" "$_pat" 1)"
			fi
		done
		info "error-priority lines this boot (up to 15):"
		printf '%s\n' "$_j" | awk 'NR <= 15 { print "        " $0 }'
		[ "$(printf '%s\n' "$_j" | awk 'END { print NR }')" -gt 15 ] &&
			info "        ($(printf '%s\n' "$_j" | awk 'END { print NR - 15 }') more suppressed)"
	fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
section "Verdict"
printf '  %d ok, %d warn, %d FAIL, %d skip\n' "$_OK" "$_WARN" "$_FAIL" "$_SKIP"
if [ "$_FAIL" -eq 0 ]; then
	printf 'no FAIL: this boot is what the repository intends. Keep the report in reports/, one file per boot worth keeping (docs/plan.md Phase 7).\n'
else
	printf 'FAIL lines above are regressions, not hypotheses: map each one to a cause before keeping the report (docs/plan.md Phase 7).\n'
fi
if [ "$IN_CHROOT" = 1 ]; then
	printf 'Live sections were skipped because this is a chroot: only a booted card can produce the report Phase 7 wants.\n'
fi
exit "$_FAIL"
