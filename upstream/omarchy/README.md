# Upstream proposal: `aarch64-google`

The vendored patch under `patches/` **is** the proposal to `omacom/omarchy`
(docs/plan.md §6, §8): it teaches Omarchy to recognise Chrome OS device-tree
boards (`google,` vendor prefix) as a hardware family of their own, so a
Chromebook that boots a signed depthcharge FIT is not mistaken for a generic
`aarch64` machine whose boot chain Omarchy cannot drive.

Base: `omacom/omarchy`, branch `quattro`, commit
`51bfd1dbaa1b5f790e19623faf2745945d40c796` (retrieved 2026-10-16). Unpatched,
the detector maps `google,` to plain **`aarch64`** (docs/recon.md §1) — no error,
but every lifecycle operation is a no-op and hardware setup never runs.

## What the patch changes

| File | Change |
|---|---|
| `bin/omarchy-hw-platform` | recognise the `google,` vendor prefix → `aarch64-google`; add it to the allowed-platform regex and the image-manifest mapping (`platform=google`); exclude it from the NVIDIA contradiction checks |
| `bin/omarchy-hw-aarch64-google` | new platform-detection helper (mirrors `omarchy-hw-aarch64-apple`); the hardware leaves gate on it |
| `bin/omarchy-lifecycle-dispatch` | register `aarch64-google`: `setup-boot` and `update-verify` **required** on `/usr/lib/omarchy/google-boot` (package `omarchy-google-boot`); `setup-system`, `setup-user`, `post-install`, `pre-remove` optional on `/usr/lib/omarchy/google` (package `omarchy-google`). Provisioning, factory reset and `luks-slots` stay no-ops (no LUKS) |
| `bin/omarchy-pkg-defaults` | compose `install/omarchy-aarch64-google.packages` for the platform |
| `install/omarchy-aarch64-google.packages` | new package list: `vboot-utils` (cgpt+crossystem+futility), `depthcharge-tools`, `keyd`, `alsa-ucm-conf`, `alsa-utils`, `pipewire-alsa`, `linux-firmware-mediatek`, `linux-firmware-realtek` |
| `install/hardware/google/{firmware,audio,keyboard,boot}.sh` | new `aarch64-google`-gated leaves, wired into `install/hardware/all.sh` |
| `install/helpers/image-target.sh` | accept `platform=google` in the build manifest (maps to `aarch64-google`), so an image can defer its hardware setup to first boot on a Chrome OS device |
| `install/helpers/pacman.sh` | map `aarch64-google` to the shared aarch64 pacman templates and the `edge` channel, like the other ARM platforms |
| `install/config/snapper.sh` | skip when `snapper` is not installed: the platform has no btrfs, so there is nothing to configure and the leaf would otherwise abort the install |
| `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` | an `aarch64-google` machine's boot package owns its initramfs (the signed FIT is built from it), so the baseline leaves `HOOKS` alone like a platform-owned Mac, instead of asking for `plymouth`/`btrfs-overlayfs` hooks this boot chain does not use |

The entrypoints themselves (`omarchy-google-boot`, `omarchy-google`) are **not**
part of this patch: like Apple's `omarchy-mac-boot`/`omarchy-mac`, they ship in
the platform's own package (built here, published into the local `[platform]`
bundle), so upstream takes only the registration.

## Deliberate deviations from docs/plan.md §6

- **Platform data is not in the patch.** §6 lists `/usr/share/omarchy-platform/google/`,
  but the contract in `docs/lifecycle-dispatch.md` says only the installed
  platform package owns that root and "Omarchy ships nothing in it". Those files
  (`displays.conf`, `audio.json`, `key-names`) therefore belong to our platform
  package, not to `omacom/omarchy`.
- **`bin/omarchy-hw-aarch64-google` is added**, which §6 does not name: the
  hardware leaves gate on a helper, exactly as `omarchy-hw-aarch64-qualcomm` does.

## How it is applied

`build-rootfs.sh` applies this patch (in `series` order) to a pinned Omarchy
checkout before installing the Omarchy packages. While the proposal is open the
patch is the single source of truth; once it lands upstream the patch is deleted
and the build uses stock Omarchy (docs/plan.md §8).

## Still to do before opening the PR (Phase 8)

- Update the tests that enumerate platforms: `test/shell.d/hw-platform-test.sh`,
  `lifecycle-dispatch-test.sh` (`apple_optional` and the platform fixtures),
  `platform-packages-test.sh`, `image-target-platform-test.sh`,
  `platform-setup-test.sh`, `update-boot-verify-test.sh`.
- Update `docs/lifecycle-dispatch.md` (registration table) and
  `docs/file-layout.md`.
- Check the remaining platform enumerations the patch does not touch yet:
  `bin/omarchy-hw-apple-silicon`, `bin/omarchy-hibernation-setup`,
  `bin/omarchy-setup-direct-boot`, `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf`,
  `install/hardware/fix-fkeys.sh`, `default/omarchy/omarchy-menu.jsonc`.
- Fill in the hardware leaves with the real device configuration (keyd mapping
  and exclusions, UCM, the `kern_guid`-resolved kpart rebuild), which currently
  only install packages (docs/plan.md §6, Phase 4).
