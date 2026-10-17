#!/bin/bash
# Collect the context of a boot that needs explaining (docs/plan.md Phase 7).
#
# check-system.sh says *what* is wrong; this says *why*, for the failures whose
# cause is only in the journal: a greeter that will not log anyone in, a unit
# that failed to start, a service that never matched a device. It is standalone
# (no repository needed), read-only (no test writes anywhere, no service is
# restarted) and English like every other artifact here.
#
# Run it on the booted system, as a user with passwordless sudo, and keep the
# output beside the report it explains:
#
#   scripts/collect-diagnostics.sh > reports/<date>-diagnostics.txt
#
# Sections are printed as "## <name>" so the file can be grepped and split.
set -uo pipefail

if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
	printf 'collect-diagnostics: needs passwordless sudo (the journal and dmesg are root-readable)\n' >&2
	exit 2
fi

say() { printf '\n## %s\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || printf '  (exit %s)\n' "$?"; }
# Commands that may legitimately print a lot: keep the tail.
tail_run() {
	local n="$1"
	shift
	printf '$ %s | tail -n %s\n' "$*" "$n"
	"$@" 2>&1 | tail -n "$n" || true
}

printf 'collect-diagnostics on %s (%s) at %s as %s\n' "$(uname -n)" "$(uname -r)" "$(date -Is)" "$(id -un)"

# ---------------------------------------------------------------------------
say "Identity"
run findmnt -n -o SOURCE,TARGET /
run cat /proc/cmdline
run cat /etc/os-release
[ -r /proc/device-tree/model ] && printf '  model: %s\n' "$(tr -d '\0' </proc/device-tree/model)"

# ---------------------------------------------------------------------------
say "First boot"
run ls -la /var/lib/omarchy/image/
for f in target target.booted deferred-steps pacman-keyring initramfs-inputs boot-rebuild; do
	[ -e "/var/lib/omarchy/image/$f" ] && { printf '  %s: ' "$f"; head -c 200 "/var/lib/omarchy/image/$f" 2>/dev/null | tr '\n' ' '; printf '\n'; }
done
run systemctl status --no-pager omarchy-provision-hardware.service

# ---------------------------------------------------------------------------
say "Packaging and keys"
printf '  keyring UIDs matching omarchy/book/build:\n'
sudo -n pacman-key --list-keys 2>/dev/null | grep -iE 'omarchy|book|build' | sed 's/^/    /' || true
sudo -n pacman-key --list-keys 2>/dev/null | awk '/^pub/{n++} END{printf "  (%d keys in the keyring)\n", n}'
run pacman -Q linux-omarchy-book linux-omarchy-book-headers
printf '  exact-name hits for linux-omarchy/linux-omarchy-headers (pacman -Q matches by pattern): '
pacman -Qq 2>/dev/null | grep -xE 'linux-omarchy(-headers)?' | tr '\n' ' ' || true
printf '\n'
printf '  keyring files shipped for the first boot to populate:\n'
ls -l /usr/share/pacman/keyrings/ | sed 's/^/    /' || true
run grep -n 'IgnorePkg\|^\[platform\]\|^\[omarchy\]\|^Server' /etc/pacman.conf

# ---------------------------------------------------------------------------
say "Memory and swap"
run free -h
run cat /proc/swaps
run zramctl
run ls -l /etc/systemd/zram-generator.conf /usr/lib/systemd/zram-generator.conf.d/ /etc/systemd/zram-generator.conf.d/ 2>&1
run cat /etc/systemd/zram-generator.conf
run systemctl status --no-pager 'systemd-zram-setup@zram0.service'
run systemctl list-units --no-pager --all 'systemd-zram*'
tail_run 40 sudo -n dmesg --level=err,warn

# ---------------------------------------------------------------------------
say "Session (sddm)"
run systemctl status --no-pager sddm.service
tail_run 60 sudo -n journalctl -b -u sddm --no-pager
# journalctl's --grep takes one pattern and its -i is a different option, so
# filter with grep instead: this is the greeter's own dialogue (login attempts,
# PAM) and the compositor SDDM starts for it.
printf '  greeter, compositor and PAM lines:\n'
sudo -n journalctl -b --no-pager 2>/dev/null |
	grep -iE 'greeter|start-hyprland|uwsm|hyprland|wayland|sddm-helper|pam_unix|session-' |
	tail -n 60 | sed 's/^/    /' || true
# The greeter's compositor logs to its own runtime directory, next to the socket
# it talks to SDDM over. Nothing here means the greeter never got that far.
printf '  greeter runtime dirs and compositor log:\n'
ls -la /run/user/*/hypr/*/ 2>/dev/null | sed 's/^/    /' | head -20 || true
for _f in /run/user/*/hypr/*/hyprland.log; do
	[ -f "$_f" ] || continue
	printf '    --- %s\n' "$_f"
	sudo -n tail -n 30 "$_f" 2>/dev/null | sed 's/^/    /' || true
done
[ -r /var/log/sddm.log ] && tail_run 40 cat /var/log/sddm.log
run cat /usr/share/sddm/hyprland.lua 2>/dev/null
run ls -l /usr/share/sddm/hyprland.lua /usr/share/wayland-sessions/ /usr/share/sddm/themes/
run cat /etc/sddm.conf.d/10-wayland.conf /etc/sddm.conf.d/10-theme.conf
run loginctl list-sessions --no-legend
run ls -la /run/user/
printf '  accounts (name, uid, home, shell):\n'
grep -hE '^(omarchy|alarm|sddm):' /etc/passwd 2>/dev/null | cut -d: -f1,3,6,7 | sed 's/^/    /'
run ls -la /home/omarchy/ 2>&1
run ls -la /home/omarchy/.config/ 2>&1
run ls -la /home/omarchy/.config/hypr/ 2>&1
printf '  user manager state for the desktop user:\n'
run loginctl show-user omarchy

# ---------------------------------------------------------------------------
say "Input and keyd"
run systemctl status --no-pager keyd.service
tail_run 30 sudo -n journalctl -b -u keyd --no-pager
printf '  input devices (name and handler):\n'
grep -E '^N: Name=|^H: Handlers=' /proc/bus/input/devices 2>/dev/null | sed 's/^/    /' || true
run grep -n -A6 '^\[ids\]' /etc/keyd/default.conf

# ---------------------------------------------------------------------------
say "Firewall"
run systemctl status --no-pager ufw.service
tail_run 30 sudo -n journalctl -b -u ufw --no-pager
run sudo -n ufw status verbose
run bash -c "lsmod | grep -E 'zram|nf_tables|iptable|nft_'"
tail_run 30 sudo -n nft list ruleset

# ---------------------------------------------------------------------------
say "Errors this boot"
tail_run 60 sudo -n journalctl -b -p err --no-pager
tail_run 40 sudo -n journalctl -b -u systemd-modules-load --no-pager

printf '\n## Done\n'
