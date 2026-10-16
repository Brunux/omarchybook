# AGENTS.md

## Project state (read this first)

**Greenfield.** The only file here is `docs/plan.md`. There is no `README.md`, no `git` repo,
and no `devices/`, `kernels/`, `scripts/`, etc. yet — plan §4 is the *target* layout, not the
current tree. Do not assume scripts or manifests exist; check before referencing them.
`git init` is itself an outstanding task (plan §9).

`docs/plan.md` is the source of truth for scope, decisions, naming and phase order. Read it
before proposing or writing anything; it is more current than this summary. Phase 0 is
read-only recon whose answers may still change the design.

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
- Upstream platform family proposed: **`aarch64-google`** (via the `google,` device-tree prefix).
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
- Never publish build output straight from a rootfs: it carries Wi-Fi PSKs, SSH host keys and
  machine-id. Reproduce `debian-aarch64`'s `lib-dist.sh` sanitize-and-assert rule (plan §6).
