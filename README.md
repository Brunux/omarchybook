# omarchybook — Omarchy on the Google Hayato Chromebook

A **device-agnostic** framework that brings **Omarchy v4 (`quattro`)** — Arch Linux ARM,
Hyprland, Quickshell and the `omarchy-*` tooling — to the **Google Hayato** Chromebook
(MediaTek MT8192, `google-asurada`, no UEFI).

It reuses the boot chain, kernel and device knowledge already proven in
[`debian-aarch64`](../debian-aarch64) (v0.1.0, verified on hardware) and replaces only the
distribution: Arch Linux ARM + Omarchy instead of Debian plus a hand-written sway UI.

- **Status:** phases 0–6 of the plan are done as far as an off-device build can take them. The
  kernel (`linux-omarchy-book`) and both platform packages (`omarchy-google`, `omarchy-google-boot`)
  build and publish into a signed `[platform]` bundle outside the repository, a rootfs builds and
  installs from it, and `scripts/` writes a card (`write-sd.sh`), an image and a release
  (`make-image.sh`, `make-release.sh`, with the bundle published as a repository), installs it to the
  eMMC (`install-emmc.sh`) and backs a machine up and restores it (`backup-system.sh`,
  `restore-system.sh`) — all rehearsed on loop devices. Phase 7 (hardware validation) is next: its
  report tool (`scripts/check-system.sh`) is written and every check is mapped to a measurement in
  `docs/recon.md` §14; nothing has booted on hardware yet, so `reports/` is empty.
- **Plan:** [`docs/plan.md`](docs/plan.md), each phase ticked with what verified it
- **Evidence:** [`docs/recon.md`](docs/recon.md), the measurements behind every decision
- **Agent/build instructions:** [`AGENTS.md`](AGENTS.md)

> **How this project is developed:** by an AI agent running on [OpenCode](https://opencode.ai)
> together with the maintainer. All versioned artifacts (code, comments, commits, docs, scripts)
> are written in **English**; discussion may be Spanish and/or English.

## Scope of v0.1

In: our kernel (mainline + MT8192 patches), our boot chain (ChromeOS GPT plus a signed
depthcharge FIT `kpart`), the Hayato device quirks (keyd, ALSA UCM, backlight udev rule, RTW88
firmware, zram), and reproducible artifacts built away from the device (bootable image, rootfs
tarball, signed kpart, `SHA256SUMS`, install/backup/restore tooling, check report).

Out: LUKS (and Omarchy's factory-reset/re-key paths), snapper/btrfs snapshots, UEFI/GRUB/Limine,
and the Apple Silicon / Qualcomm / NVIDIA platform code. See plan §1 for the full list.
