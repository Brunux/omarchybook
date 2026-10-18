# AGENTS.md

## Project state (read this first)

Phases 0–6 of `docs/plan.md` are done as far as an off-device build can take them: the repository
has `devices/`, `kernels/`, `boot/`, `platform/`, `scripts/`, `packages/`, `upstream/` and `keys/`,
the kernel and both platform packages publish into a signed `[platform]` bundle outside the repo, a
rootfs builds and installs from it, and Phase 6's tooling writes a card or an image from that rootfs
and backs a machine up and restores it. Phase 7 (hardware validation) is in progress: its report tool
`scripts/check-system.sh` is written (every check mapped to a measurement in `docs/recon.md` §14;
it stands its live sections down in a chroot or a sandbox instead of describing the wrong machine),
and three cards have booted on the Hayato and left their report and diagnostics in `reports/`. What
each round finds is mapped to a cause in recon §14 and fixed in the image, never on the card: the
first two rounds found real bugs (SDDM's missing owner state, netfilter matches the kernel was not
building, the `[platform]` keyring, and a home that was never seeded from `/etc/skel`), the third
found three in the report itself, and a kept report with no FAIL is what Phase 7's acceptance still
waits for.

**v0.1.1 is published** (this repository's Releases, tag `v0.1.1`) with the notes in
`docs/releases/v0.1.1.md`: the release that carries the platform rename to `omarchy-book` /
`omarchy-book-boot`, the installer the device ships following pmbootstrap's path, and the two `-dev`
packages at `pkgrel=2`. `build-omarchy.sh`'s rebuild stamp hashes the vendored recipes as well as
the commit and the patch, so that bump is not skipped. v0.1.0's three-card validation — and the one
FAIL that was the report's own probe (recon §14) — was of the image *that* release carried; no card
has booted v0.1.1 yet, so the report that confirms the rename and the installer fix is still what
Phase 7's acceptance waits for. Building a release again wants about **25 GiB of working disk** —
the rootfs, the image and `lib-dist.sh`'s staging copy exist at once — and both the image and the
rootfs tarball come out over the **2 GiB a file in a GitHub release may be**, so they ship as 1800
MiB parts (`<name>.part-aa`, …): reassemble with `cat <name>.part-* > <name>` and check against
`SHA256SUMS`, which hashes the whole file. Three things the first real build got wrong are fixed
(recon §13): the raw `.img` is neither published nor listed in `SHA256SUMS`, and `RELEASE-INFO.txt`
reads the commit and the tag together, pinned to the same commit.

Two Phase 6 decisions are easy to undo by accident: a release also publishes the bundle as a
repository (`platform/`) and an image takes it only when `PLATFORM_REPO_URL` is set, and a package
that a release already carries gets a `pkgrel` bump before it is republished. ALARM's `alarm`
account stays in the image on purpose, and `make-release.sh` warns about every account with a
password at publish time (plan §3, decisions 7 and 8).

`docs/plan.md` is the source of truth for scope, decisions, naming and phase order — each phase is
ticked with the evidence that verified it, and unticked items say what they wait on. Read it before
proposing or writing anything. `docs/recon.md` holds the measurements behind those answers,
including the porting bugs in §12 and §13. Do not assume a script, manifest or package exists: check
the phase that creates it.

## What this is

Port **Omarchy v4 (`quattro`)** — Arch Linux ARM + Hyprland + Quickshell — to the **Google
Hayato** Chromebook (MediaTek MT8192, device dir `devices/google-asurada/`, no UEFI). Stock
Omarchy aarch64 boots via UEFI+GRUB/Limine; this device boots a **signed depthcharge FIT
`kpart`** from the GPT kernel partition, so the boot chain is script-level and is ported from
the sibling project below. Artifacts are built away from the device (image, rootfs tarball,
signed kpart, SHA256SUMS).

## Reference repo — consult, do not reinvent

`~/Dev/debian-aarch64` is the released, hardware-verified (v0.1.0) sibling this project ports
from. Its `AGENTS.md` documents the hard-won gotchas: `cgpt`/`parted` ordering, kpart signing
and `hayato`-first DTB order, keyd exclusions and `KEY_SLEEP`/suspend, the MT8192 UCM boot
sequence, SCP firmware noise, `/tmp` size limits, and the POSIX-sh/`pipefail` rules. Port the
logic; change only package names and paths (plan §2.3). Vendoring copies (not submodules) is
deliberate: each repo must build and release from its own HEAD.

## Decided names (plan §3) — easy to get wrong

- Kernel package: **`linux-omarchy-book`** and `linux-omarchy-book-headers` (not
  `linux-omarchy`); `provides`/`conflicts` against the upstream kernel package.
- Platform packages: **`omarchy-book`** and **`omarchy-book-boot`** (dirs
  `/usr/lib/omarchy/book{,-boot}`) — the platform brand, like upstream's
  `aarch64-apple` → `omarchy-mac`/`omarchy-mac-boot`. Not `omarchy-google*`.
- Upstream platform family proposed: **`aarch64-google`** (via the `google,` device-tree prefix);
  the per-platform list stays `install/omarchy-aarch64-google.packages`.
- Channel: **`edge` only** — the only channel publishing aarch64. Pinning policy holds nothing
  but `IgnorePkg` for `linux-omarchy*` plus versions recorded in `docs/recon.md`.

## Upstream sources (`omacom/`)

| Repo | Branch | Use |
|---|---|---|
| `omarchy` | `quattro` | shell/tooling to patch and install |
| `omarchy-pkgs` | `master` | PKGBUILD templates; `pkgs.omarchy.org/edge/aarch64` |
| `omarchy-iso` | `quattro` | image builder + pacman configs to model after |
| `omarchy-mac-pkgs` | `main` | platform-implementation model for `aarch64-google` |

A `google,` prefix currently resolves to plain `aarch64` (no lifecycle ops). The vendored patch
`upstream/omarchy/patches/0001-aarch64-google.patch` *is* the upstream proposal (plan §6); keep
the patch and the proposal in sync and delete it once merged.

## Conventions

- All versioned artifacts are **English** (code, comments, commits, docs, scripts). Discussion
  with the maintainer may be **Spanish and/or English**, but artifacts are English only. This
  carries over from `debian-aarch64`.
- Never publish build output straight from a rootfs: it carries the maintainer's Wi-Fi PSKs, SSH
  host keys, machine-id — and, as Phase 6 found, this repository's own build state. The rule is
  `scripts/lib-dist.sh` (plan Phase 6, recon §13): those paths are *excluded from the copy* (deleting
  them afterwards leaves their bytes in the image's free blocks) and the finished artifact is
  byte-searched for the profiles' contents.
- The installer (`boot/lib-cgpt.sh`, used by `write-sd.sh`, `install-emmc.sh`, `make-image.sh` and
  `restore-system.sh`) follows pmbootstrap's install path part by part, because that is the method
  proven to boot on this machine — and it ships inside the `omarchy-book-boot` package, so a change
  here needs that package rebuilt (and a `pkgrel` bump, plan §3 decision 7) before a device sees it.
  Read recon §12 before changing it: the geometry (`- 33`, not `- 2048`), the mounted-partition
  refusal (`findmnt -rn -S <device>`, never `mountpoint -q <device>`), the partition resolution (by
  `PARTN`, never by position in `lsblk`), the fstab options (`/boot` gets `nodev,nosuid,noexec`; the
  root keeps `errors=remount-ro`, which pmbootstrap does not set) and the kpart's command-line
  separator are all deliberate.
- Shell scripts run under `set -euo pipefail` on a host whose `du` and `cp` are BusyBox: no GNU-only
  flags (`du_mib`/`file_mib` in `scripts/lib.sh`), and a `cmd | head`/`| grep -q` needs `|| true`
  unless the writer exits on its own (recon §12, §13).
