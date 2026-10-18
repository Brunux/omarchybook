# Origins of the files in this package

This package is this repository's own, like `kernels/<flavor>/PKGBUILD`, but two
of its files are ports of another project's, and a port is only trustworthy if
what it encodes is recorded. The vendoring rule of `docs/plan.md` §2.5 applies:
port the logic, change only names and paths.

**`etc/keyd/default.conf`** — ported from `debian-aarch64`'s
`uis/sway/files/etc/keyd/default.conf` (v0.1.0, hardware-verified on this very
machine: `reports/check-system-2026-10-16-card-2.txt` records the keyboard,
suspend and brightness checks passing). The layers (`[main]`, `[meta]`,
`[alt]`, `[control]`, `[control+alt]`, `[altgr]`) are verbatim. The comments
were adapted: they name Hyprland instead of sway, Omarchy's lock-on-suspend
instead of `swaylock`, and Arch's `keyd` binary instead of Debian's
`keyd.rvaiya`. The `[ids]` section is the hard-won part and is unchanged:
`cros_ec_buttons` and the headset jack share the internal keyboard's
`0000:0000` id, so they must be excluded **before** the generic `k:0000:0000`
entry — grabbing them takes the power button and the lid switch away from
systemd-logind, and the machine stops suspending on lid close.

**`usr/lib/udev/rules.d/90-brightnessctl.rules`** — the rule upstream
`brightnessctl` installs, which both Debian's and Arch's packages leave out
(checked: `pacman -Ql brightnessctl` on ALARM ships no udev or polkit file).
Taken from the same repository's `uis/sway/files/etc/udev/rules.d/`, where it is
what makes the brightness keys work for an unprivileged session.

Everything else was written for this port: `share/omarchy-platform/key-names`,
`usr/lib/systemd/journald.conf.d/10-omarchy-book.conf`, the entrypoint, the
setup script, the packaging and the tests.
