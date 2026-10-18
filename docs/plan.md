# omarchybook — Omarchy (Arch Linux ARM + Hyprland) on the Google Hayato Chromebook

Plan for a new, device-agnostic repository, `~/Dev/omarchybook`, that brings **Omarchy v4
(`quattro`)** to the Google Hayato rev1 (MediaTek MT8192 `google-asurada`, ASUS Chromebook
Detachable / Flip CM3 CM3200, 4 GB RAM, 58.2 GB eMMC, stock coreboot/depthcharge).

It reuses the same boot chain, kernel and device knowledge that already work in
`~/Dev/debian-aarch64` (v0.1.0, released and verified on hardware), and replaces only the
distribution: **Arch Linux ARM + Omarchy packages** instead of Debian plus a hand-written sway UI.

> Status of the sibling project: `debian-aarch64` is **paused** (v0.1.0 published, tag pushed,
> four release assets, Nura's backup on an exFAT stick verified, `restore-system.sh` rehearsed end
> to end). The only outstanding item there is `CONFIRM=yes sudo scripts/install-emmc.sh` run from
> the booted card. Nothing in this plan blocks or depends on it.

---

## 1. Goal

Run Omarchy — Arch Linux, Hyprland, Quickshell, its themes and its `omarchy-*` tooling — on the
Hayato, with:

1. **our kernel** (mainline 7.2.7 plus the MT8192 patches that already boot this machine);
2. **our boot chain** (ChromeOS GPT plus a signed depthcharge FIT in the kernel partition), because
   the Hayato has no UEFI and Omarchy's aarch64 path is UEFI + GRUB/Limine;
3. **our device layer** (the `aarch64-google` platform package, `platform/omarchy-google/`: keyd for
   a keyboard with no F1–F10, the ALSA UCM boot sequence, the backlight udev rule, RTW88 firmware,
   zram);
4. reproducible artifacts built **away from the device**: a bootable microSD image, a rootfs
   tarball, a signed kpart and SHA256SUMS, plus install/backup/restore tooling and a check report.

Non-goals for v0.1: LUKS (and with it Omarchy's factory-reset/LUKS-rekey paths), snapper/btrfs
snapshots (a snapshot cannot be booted from the ChromeOS kernel partition), UEFI/GRUB/Limine, and
the Apple Silicon/Qualcomm/NVIDIA platform code.

---

## 2. Recon: what Omarchy actually is, and what of it applies

### 2.1 Omarchy v4 supports aarch64 as a first-class image target

Organization `omacom` (69 repositories). The relevant ones:

| Repository | Branch | Role |
|---|---|---|
| `omarchy` | `quattro` | the shell and tooling: `bin/`, `install/`, `config/`, `default/`, `etc/`, `shell/`, `themes/`, `migrations/` |
| `omarchy-pkgs` | `master` | PKGBUILDs for everything Omarchy ships from `pkgs.omarchy.org/<channel>/<arch>` |
| `omarchy-iso` | `quattro` | the image builder (archiso profile plus orchestrator) |
| `omarchy-mac-pkgs` | `main` | the Apple Silicon platform implementation (the model for ours) |
| `linux-aurora` | `integration/aurora` | their kernel source tree (not needed: we bring ours) |

Evidence that aarch64 is real, not aspirational:

- `omarchy-pkgs/README.md`: *"Channels: `edge` → `rc` → `stable`. Packages only move forward.
  **Architectures: `x86_64` and `aarch64`.**"* Recipes live in `pkgbuilds/<package>/PKGBUILD` with
  `.omarchy/package.json`; builds run in Docker/Podman, so aarch64 is built natively in their CI
  (ARM runners), not cross-compiled.
- `omarchy-iso/quattro/plans/aarch64-support.md`: a parallel **generic UEFI aarch64** ISO
  (Ampere, Graviton, Snapdragon X, ARM dev kits). Out of scope there: Apple Silicon and
  U-Boot/`rpi-firmware` boards. It names the hard prerequisite exactly as we found it: vanilla
  Arch has no `core/os/aarch64`, so the base is **Arch Linux ARM**.
- `omarchy-iso/quattro/builder/`: `aarch64-package-filter.sh`, `arm64-kernel-image.sh`,
  `linux-omarchy.preset`, `archiso-aarch64-mkinitcpio.sh`, `archiso-aarch64-grub-modules.sh`,
  `archiso-v87-aarch64-{boot-efi,grub}.patch`, `grub-platform.sh`, `build-omarchy-packages.sh`,
  `qualcomm/`.
- `omarchy-iso/quattro/configs/pacman-online-aarch64.conf`: `Architecture = aarch64`, with repo
  precedence `[platform]` → `[omarchy]` → `core`/`extra`/`alarm`/`aur`:

  | Repo | Server |
  |---|---|
  | `[platform]` | `file:///packages` (build-time bundle indexed with `repo-add`; "a build without a bundle drops it") |
  | `[omarchy]` | `https://pkgs.omarchy.org/edge/$arch` (aarch64 published **on the edge channel only**) |
  | `core`/`extra`/`alarm`/`aur` | `https://arm-mirror.omarchy.org/$arch/$repo` (Arch Linux ARM, mirrored by Omarchy) |

  Its own comments state the intent, and it is exactly the seam we will use:
  *"[omarchy] carries builds that must win over Arch Linux ARM's (Hyprland against the current
  aquamarine)"* and *"[platform] pins a kernel under test and anything held at a version proven on
  the hardware"*.
- `omarchy-iso/quattro/README.md`: *"The Omarchy ISO is the only supported way to install Omarchy.
  It includes the Omarchy Configurator and installs Arch Linux and the Omarchy packages from the
  bundled mirror. It then runs target system setup in the chroot, creates the user, and runs
  `omarchy-provision-user` for that user."*

### 2.2 Verified live: the aarch64 package set is already published

`https://pkgs.omarchy.org/edge/aarch64/omarchy.db` → **197 packages**. Present (sampled):
`omarchy`, `omarchy-settings`, `omarchy-dev`, `omarchy-settings-dev`, `quickshell`, `hyprland`,
`omarchy-hyprland-titlebars`, `aquamarine`, `aether`, `ghostty`, `walker`, `ttfx`, `herdr`,
`omasnap`, `gliff`, `cliamp`, `owe`, `owe-lockfeed`, `signed`, `monologue`, `hype`, `omacalc`,
`omawrite`, `omareel`, `linux-omarchy`, `linux-omarchy-headers`, `yay`, `mise-bin`.

Absent from `[omarchy]` but present in Arch/ALARM: `uwsm`, `sddm`, `mise`.

The upstream `linux-omarchy` recipe is `pkgbase=linux-omarchy`, `pkgver=7.2.8`, with functions
`package_linux-omarchy()` and `package_linux-omarchy-headers()`. **Same series as our 7.2.7 plus
patches**, so their PKGBUILD is a usable template and our patches should carry forward to 7.2.8 if
we ever want to move.

`builder/aarch64-package-filter.sh` encodes the x86→arm porting knowledge we would otherwise have to
rediscover: it takes the platform kernel name as an argument and rewrites
`linux|linux-omarchy|linux-t2` → `$kernel`, `*-headers` likewise, `nvim` → `neovim` ("Arch Linux ARM
still ships Neovim under its previous name"), and the list is deliberately closed — anything else
missing fails the build. x86-only packages are dropped explicitly (microcode, `nvidia-*`, `asusctl`,
`thermald`, `intel-*`, `t2*`, `memtest`, `broadcom-wl`, `lib32-*`); `obs-studio` and `yay-debug` are
not yet published for aarch64.

### 2.3 The one piece that does not fit: the boot chain

Omarchy's aarch64 boots via **UEFI + GRUB** (live ISO) and **Limine + UKIs** (installed system).
The Hayato has stock coreboot/depthcharge and no UEFI: it boots a **signed FIT "kpart"** from the
partition whose PARTUUID equals `kern_guid` in the kernel command line. Therefore none of
`limine*`, `limine-entry-tool`, `limine-mkinitcpio-hook`, `snapper`, `plymouth` or UKIs apply; the
kernel lives *inside* p1, and a kernel update is not finished until p1 is rewritten.

This is precisely the problem `debian-aarch64` already solved, and the solution is **script-level**,
so it ports almost verbatim: `boot/lib-cgpt.sh` (the single copy of the ChromeOS GPT layout),
`boot/make-kpart.sh` (`depthchargectl build --board mt8192` plus the vboot developer keys),
`boot/install-kpart.sh` (resolves `kern_guid` from `/proc/cmdline`, verifies that the FIT fits and
is signed, backs up what it replaces), plus `write-sd.sh`, `install-emmc.sh`, `make-image.sh`,
`make-release.sh`, `backup-system.sh` and `restore-system.sh`. The shell logic ports as it is (the
Debian originals are POSIX sh; ours are bash, which is what Arch's `/bin/sh` is, and the ports lean
on `pipefail`), so the work is package names and paths — with one genuine fix the Debian copies
carried: `install-kpart.sh`'s chroot guard never fired, and would have let a chroot rewrite the
*host's* kernel partition (recon §12).

### 2.4 The integration contract (and where it can bite)

`bin/omarchy-hw-platform` (read in full) is a `bash -p` script that resolves a machine to
`x86 | aarch64 | aarch64-apple | aarch64-qualcomm | aarch64-n1x | aarch64-gb10`:

- it reads the device-tree root `compatible` (`/proc/device-tree/compatible`, or
  `/sys/firmware/devicetree/base/compatible`), and **only a token's vendor prefix counts**;
  `OMARCHY_PROC_ROOT` / `OMARCHY_SYS_ROOT` override those paths, so the detector can be exercised
  off-device against a fake device tree;
- an image manifest (a root-owned regular file, `format=1`) can pin the platform, with the names
  `apple-silicon` → `aarch64-apple`, `generic-aarch64` → `aarch64`, `generic` → `x86`,
  `qualcomm` → `aarch64-qualcomm`; the allowed regex is
  `^(x86|aarch64|aarch64-apple|aarch64-qualcomm|aarch64-n1x|aarch64-gb10)$`;
- contradictions (an `apple,` device tree on a non-ARM CPU, say) are a hard `exit 1`;
- the final `case` maps `apple,*` → `aarch64-apple`, `qcom,*` → `aarch64-qualcomm`, and
  **everything else → plain `aarch64` on an ARM CPU**.

Consequence: a `google,` vendor prefix yields plain `aarch64` **today** — no error, no family. And
because registering a platform is *code* in `bin/omarchy-lifecycle-dispatch` (not configuration),
plain `aarch64` means every lifecycle operation resolves to nothing.

The supported, non-invasive extension points are:

- `/usr/share/omarchy-platform/` — `displays.conf`, `key-names`, `audio.json`, `keyrings`,
  `display-cutouts.json` (describe hardware without patching Omarchy);
- `install/hardware/*` leaves and the lifecycle operations `setup-boot` and `setup-system` (from
  `install/hardware/platform-setup.sh`), `update-verify`, `provision-commit`, `provision-verify`,
  `reset-*`, `post-install <app>`;
- prebuilt images: `/var/lib/omarchy/image/target` (`format=1`, `platform=<name>`) queues the
  hardware leaves to first boot through `omarchy-provision-hardware`
  (`install/helpers/image-target.sh`) — the model that matches this project's "build away from the
  device" requirement.

### 2.5 Reused from `debian-aarch64` (provenance)

Vendored into this repository with a note recording origin and commit: `kernels/mediatek-mt81/`
(`version`, `config.aarch64`, `patches/series`), `devices/google-asurada/` (`deviceinfo`,
`kernel-cmdline.conf`, `modules-initfs`), `lib-cgpt.sh`, `make-kpart.sh`, and the
install/backup/restore/image patterns. `debian-aarch64` stays as it is; the copy makes each
repository independently reproducible.

Device knowledge that must not be lost in the port (each item cost hardware debugging):

- `cgpt create` must not be given `-z` (it zeroes the GPT areas after writing them);
- `cgpt` writes no protective MBR, so `parted -s <dev> mktable gpt` comes first, then
  `partx -d` plus `partx -a` (`blockdev --rereadpt` returns EBUSY on this card);
- `lsblk -nro PATH <disk>` lists the disk first — skip that line when resolving `p1`/`p2`/`p3`;
- `mkdepthcharge` prepends `kern_guid=%U` itself, and the board is `mt8192`, not `asurada`;
- the FIT's default config is the first DTB, so **hayato must stay first**;
- the keyboard has no F1–F10: `keyd` supplies them (`Ctrl+Alt` plus the top row = VT 1–10,
  `Search` plus the top row = F1–F10), and it must **exclude `cros_ec_buttons` and the headset
  jack** (both share the keyboard's `0000:0000` id) or suspend-on-lid-close, tablet mode and the
  power button die;
- the Lock key emits `KEY_SLEEP`, which is logind's own suspend: do **not** remap it to
  `KEY_COFFEE` (that is what broke suspend in Nura), and bind `XF86Sleep` to the locker;
- the MT8192 audio card needs its UCM **boot sequence** run by `alsactl restore` (`alsa-utils` plus
  `alsa-ucm-conf`), otherwise the only sink is a Dummy Output;
- ALSA-only applications need PipeWire's `default` PCM (`pipewire-alsa`);
- `brightnessctl` needs a udev rule (Debian ships none; check Arch);
- the `sbs-8-000b` gauge logs `Unknown chemistry: OTC0` upstream — noise, capacity works;
- `CONFIG_MTK_SCP=m` always logs two failed early firmware loads before the real one succeeds.

---

## 3. Decisions taken

| # | Decision | Rationale |
|---|---|---|
| 1 | **Channel: `edge`** | The only channel publishing aarch64. Policy is the simplest one that stays safe: no channel snapshot and no mirrored copy — just `IgnorePkg` for the `linux-omarchy*` packages (already required) and the versions that make the first boot work recorded in `docs/recon.md`. |
| 2 | **Platform: propose upstream `aarch64-google`** | Registering a real family (vendor prefix `google,`) is the clean long-term answer and the honest way to use Omarchy rather than fork it. Carried as a vendored patch until it lands. |
| 3 | **Kernel package: `linux-omarchy-book`** (plus `linux-omarchy-book-headers`) | Arch's `linux-<flavor>` convention, and the name `aarch64-package-filter.sh <kernel>` and the `--package-dir` bundle expect. Provides `linux` and `linux-omarchy`, conflicts with `linux-omarchy`. |
| 4 | **Root filesystem: ext4** | p2 `/boot` 512 MiB ext4, p3 ext4 — the layout already proven here. No snapper, no btrfs: a snapshot cannot be booted from the kernel partition. |
| 5 | **Boot: ChromeOS GPT plus a signed depthcharge kpart** | The only boot path this hardware has. Layout, flags, DTB order and signing keys copied from the working port. |
| 6 | **Reuse by vendoring, not submodules** | Each repository must build and release on its own from its own HEAD. |
| 7 | **Upgrade path: a release publishes `[platform]`, and the image takes it when `PLATFORM_REPO_URL` is set** | Omarchy's own post-install leaf drops the build-time `[platform]`, which leaves a device unable to update the kernel or the platform packages at all. A release writes the bundle out as a signed repository (`platform/`); pointing a build at where it is served (`PLATFORM_REPO_URL`) writes the section back, with the signing key already trusted in every image. Empty by default, so an unreleased build carries no repository it could fail to reach. Still empty as of Phase 7 (the maintainer has not chosen where `platform/` will be served), so the first card has no `[platform]` and its report says the kernel and the platform packages are updated by reflashing. |
| 8 | **A republished package gets a `pkgrel` bump when a release already carries it; ALARM's `alarm` account stays** | The build stamps are content-based, so a recipe or patch change republishes the same version with new bytes — fine inside a build, but a machine whose database already holds that version will not move to it, so a release bumps `pkgrel`. And the `alarm` account (uid 1000, wheel, ALARM's documented password) is left alone and *documented* instead of locked: `make-release.sh` warns about every account with a password at publish time, and the release notes say to change them. |

### Naming

- Repository and working directory: `~/Dev/omarchybook` (as requested).
- Kernel: `linux-omarchy-book` and `linux-omarchy-book-headers` (flavor `omarchy-book`, confirmed).
- Device directory: `devices/google-asurada/` (board codename, matching `debian-aarch64`).
- Upstream platform family: `aarch64-google`.

**TODO — rename the kernel's naming from `google` to `mt81`** (asked for on 2026-10-17, before
anything is renamed). The kernel itself already carries the SoC: `kernels/mediatek-mt81`, release
`7.2.7-mt81`, `linux-omarchy-book`. What still says `google` is everything around it: the device
directory (`devices/google-asurada/`), which is also what names every asset the release publishes
(`google-asurada.img.xz`, `google-asurada.vmlinuz.kpart`, `google-asurada-rootfs.tar.zst`), the
platform family `aarch64-google` and its packages (`omarchy-google`, `omarchy-google-boot`), the
payload directory `/usr/lib/omarchy/google-boot/`, and the `google,` device-tree prefix the detector
keys on. Two of those are deliberately tied to names that are not ours to choose —
`aarch64-google` is what the vendored upstream patch proposes (a `google,` prefix is what the device
tree answers) and `devices/google-asurada/` matches the sibling repository — so the rename has to
decide which of the two layers moves: the artifacts (a `deviceinfo` basename, no upstream effect) or
the platform (a different family name, and the patch with it).

---

## 4. Repository layout

The same shape as `debian-aarch64`, which proved workable: device-agnostic, kernels shared between
devices, one copy of the GPT layout, and one place that decides what a published artifact may
contain.

```
omarchybook/
  devices/google-asurada/     deviceinfo, kernel-cmdline.conf, modules-initfs,
                              packages.list, PROVENANCE.md
  kernels/mediatek-mt81/      version, config.aarch64, patches/{series,*.patch},
                              PKGBUILD, APKBUILD.reference (upstream, reference only)
  packages/                   base.list (ALARM), omarchy.list (the Omarchy
                              packages installed explicitly; the desktop set
                              itself is composed from the runtime's own lists),
                              aarch64-filter.list (x86-only drops and substitutions)
  platform/omarchy-google/    the aarch64-google runtime layer, the role upstream
                              gives omarchy-mac-pkgs: PKGBUILD, the setup-system
                              entrypoint and script, the keyd map, the backlight
                              udev rule, the journald drop-in and the
                              /usr/share/omarchy-platform data
  platform/omarchy-google-boot/
                              the boot-chain half: the setup-boot and
                              update-verify entrypoints, the command they share,
                              and — through extra.list — the boot/ scripts, the
                              deviceinfo and the devkeys, plus the ALPM hook
                              that rewrites p1. Both are built into [platform]
                              like the kernel; extra.list is how a recipe stages
                              files it does not own, so neither package keeps a
                              second copy of them
  keys/                       omarchy.gpg, the [omarchy] signing key (its repo
                              ships no keyring Arch Linux ARM's trusts)
  boot/                       lib-cgpt.sh, make-kpart.sh, install-kpart.sh,
                              lib.sh, 99-omarchy-kpart.hook, devkeys/ (the ALARM
                              vboot-utils carries none); the canonical boot-chain
                              copy, consumed by scripts/ and shipped to the
                              device by platform/omarchy-google-boot. The
                              scripts source a lib beside themselves, so the same
                              files work in a checkout and on an installed
                              system, where the package replaces lib.sh with its
                              own device-side one
  upstream/omarchy/           patches/series plus 0001-aarch64-google.patch (the proposal)
  upstream/omarchy-pkgs/      the *-dev recipes the runtime and settings are
                              built from (pinned to the same quattro commit)
  upstream/depthcharge-tools/ the AUR recipe for depthchargectl, the one package
                              the device needs that no repository carries
  scripts/                    build-package.sh (recipes, ours and vendored; an
                              extra.list file lets a recipe stage files that live
                              outside it, counting towards its hash),
                              build-kernel.sh, build-omarchy.sh,
                              build-rootfs.sh,
                              write-sd.sh, make-image.sh, make-release.sh,
                              install-emmc.sh, backup-system.sh,
                              restore-system.sh, check-system.sh (Phase 7),
                              lib.sh, lib-dist.sh, 00-deps.sh
  docs/                       plan.md, recon.md, upstream.md, releases/<version>.md
  reports/                    check-system.sh output captured on real hardware
```

---

## 5. Phases

Each phase ends in a verifiable artifact; hardware checkpoints are explicit.

### Phase 0 — Recon spike (read-only, nothing written)

- [x] Run `omarchy-hw-platform` against a fake device tree whose root `compatible` is
      `google,asurada`, using `OMARCHY_PROC_ROOT`/`OMARCHY_SYS_ROOT`, and confirm it prints
      `aarch64`. *The detector's rule is the vendor prefix, so stock Omarchy answers plain
      `aarch64`; with the patch it answers `aarch64-google` (recon §1). Phase 3 re-verifies that
      from both the image manifest and a `google,asurada` tree.*
- [x] Read `bin/omarchy-lifecycle-dispatch` and `install/hardware/platform-setup.sh` and answer:
      **does a registered platform with an unimplemented operation error out or fall through?**
      If it errors, `aarch64-google` must implement every operation Omarchy calls, `reset-*`
      included, or the family must not be registered at all. *It falls through: an operation the
      platform does not list exits 0, the five it does list and has no entrypoint for exit 3, and
      only a broken entrypoint exits 1 (recon §2). So the family needs those five and nothing else,
      and that is exactly what the patch registers.*
- [x] Determine whether `setup-boot` runs inside the build chroot or at first boot. *At first boot:
      `install/hardware/platform-setup.sh` is one of the deferred hardware leaves and is what calls
      `setup-boot image-first-boot` and `setup-system image-first-boot` (recon §2), which is why the
      image build stops at installing the package.*
- [x] `pacman -Si omarchy omarchy-settings` on an ALARM chroot: do they depend on `linux-omarchy`?
      *Neither does (recon §3), which is what lets `linux-omarchy-book` own the kernel without a
      dependency fight; `omarchy-settings` does depend on `plymouth` (recon §8).*
- [x] AUR: does `depthcharge-tools` (0.6.2-1, provides `depthchargectl`/`mkdepthcharge`) and
      `vboot-utils` (provides `cgpt` and `crossystem`) ship `futility` and
      `/usr/share/vboot/devkeys`? Whatever is missing gets vendored into our `[platform]` bundle.
      *`futility` and `cgpt` both come from ALARM's `vboot-utils`; it ships **no** devkeys, so
      `boot/devkeys/` vendors them with their provenance (recon §7, §10), and a kpart built with
      them verifies with `futility show` (Phase 1).*
- [x] Confirm how the `depthcharge-tools` system hooks behave on Arch (they guess a kernel
      partition from `/proc/cmdline`; on Debian they had to be disabled or they break the build).
      *It installs no kernel or initramfs hook at all, so nothing had to be disabled (recon §7).*
- [x] Availability check on ALARM for: `keyd`, `alsa-ucm-conf`, `alsa-utils`, `linux-firmware`
      (MediaTek and RTW88 pieces), `mesa` (panfrost for Mali-G57), `chromium` (a known weak spot on
      ARM), `zram-generator`, `wireless-regdb`. *All present, versions in recon §5 (`keyd 2.6.0-5`,
      `alsa-ucm-conf`, `chromium`, `zram-generator`, `wireless-regdb`) and §11 (the rest of the
      device set, all of it installed in the built image); Mesa and the Mali firmware come with
      `mesa`/`linux-firmware`, neither needs a vendor split on this part.*
- [ ] Record the exact versions that end up installed on the first working boot into
      `docs/recon.md` (that is the whole pinning policy: `IgnorePkg` for `linux-omarchy*`, nothing
      else held). *Still open by construction — it needs the first boot on hardware (Phase 7); §5
      records what the repositories offer, not what the card ends up holding.*

**Acceptance:** every open question above answered with evidence (command plus output) in
`docs/recon.md`, including the exact upstream patch surface the `aarch64-google` family needs.
*Collapsed to recon §11 plus the vendored patch itself; only the first-boot version pin above still
waits on hardware.*

### Phase 1 — Kernel as a pacman package

- [x] `kernels/mediatek-mt81/PKGBUILD` building 7.2.7 plus `patches/series` with `make LLVM=1`
      (clang/lld), reusing `build-kernel.sh`'s proven invocation. *Verified in the ALARM chroot:
      both packages build; `kernelrelease` = `7.2.7-mt81`. `scripts/build-kernel.sh` is the
      reproducible driver — a wrapper around `scripts/build-package.sh` that says why the kernel is a
      package — and it stages the recipe into the build chroot, installs its `makedepends` as root,
      runs `makepkg -fc --nodeps` with `-j$(nproc)` (recon §9), publishes both packages into
      `[platform]`, signs them and stamps the recipe's contents so an unchanged tree is not
      recompiled. The work tree survives an interrupted build, so a killed kernel build resumes
      instead of starting over.*
- [x] `linux-omarchy-book` installs `vmlinuz-<release>` (`make zinstall` produces no plain
      `vmlinuz`), `/usr/lib/modules/<release>`, and DTBs under `/boot/dtbs/` with **hayato first**.
      *Verified: `/boot/vmlinuz-7.2.7-mt81` (gzip arm64 `Image`), modules with `pkgbase`, and
      `boot/dtbs/mediatek/mt8192-asurada-hayato-r1.dtb` — the vendor subdirectory `dtbs_install`
      creates, which is why `deviceinfo_dtb` carries the `mediatek/` prefix — sorting first.*
- [x] `linux-omarchy-book-headers`; `provides=('linux' 'linux-omarchy')`,
      `conflicts=('linux-omarchy')`, `depends` mirroring the upstream recipe. *Both packages are
      published into `[platform]` by `scripts/build-kernel.sh`; `-headers` is what a DKMS build on
      the device would install.*
- [x] mkinitcpio preset, modelled on upstream's `linux-omarchy.preset`. `CONFIG_MMC_MTK`,
      `CONFIG_DRM_MEDIATEK` and `CONFIG_EXT4_FS` are built in, so the initramfs stays small; verify
      that the `Possible missing firmware ... mali_csffw.bin for built-in driver panthor` warning is
      still just noise (it comes from initramfs-tools-style scanning of built-in drivers, and
      panthor never drives this Mali-G57). *Verified: `mkinitcpio -P` builds both images from the
      preset; the messages seen were `sd-vconsole` (no `/etc/vconsole.conf`), `drm_privacy_screen`,
      `xhci_pci_renesas` and two benign aarch64 ones: `ERROR: failed to detect root filesystem`
      (the `autodetect` hook finds no `root=` in a chroot — the kpart supplies it at boot) and the
      `microcode` hook skipping the architecture — none the `mali_csffw.bin` one.*
- [x] ALPM hook: after a kernel or initramfs change, rebuild and write the kpart — the Arch
      counterpart of the Debian sequence `install-kernel.sh` then `install-kpart.sh` — backing up
      what it replaces. *`boot/99-omarchy-kpart.hook`, shipped by `omarchy-google-boot`, fires on
      the kernel package or on `boot/vmlinuz-*`/`boot/dtbs/*` and runs `omarchy-google-boot
      kpart-rewrite`, which is Phase 5's `install-kpart.sh` with `CONFIRM=yes`. Two `[Trigger]`
      sections because pacman keeps the last value of a repeated key, and numbered 99 so it lands
      after mkinitcpio's `90-mkinitcpio-install.hook` — the FIT then embeds the regenerated
      initramfs. It cannot break a transaction: in a chroot it reports and exits 0 (the write is
      meaningless there and `/proc/cmdline` is the host's), on a booted system it rewrites p1.
      Exercised end to end in a rootfs by reinstalling the kernel package: pacman ran the hook and
      the guard skipped it (recon §12). What the hook does on a real boot is Phase 7's.*
- [x] Package signing and publication into the local `[platform]` repo via `repo-add`. *`lib.sh`
      keeps a build/release signing key outside the repository (`$BUILD_ROOT/keys`, created on first
      use), `sign_platform_packages` writes a detached signature beside each package, and
      `build-rootfs.sh` trusts the public half in the image before indexing with `repo-add`, which
      copies each signature into the database as `%PGPSIG%`. `[platform]` therefore inherits
      `SigLevel = Required DatabaseOptional` rather than needing `TrustAll` (recon §10). Every entry
      in the bundle is reproducible from this repository: `depthcharge-tools`' AUR recipe is vendored
      (`upstream/depthcharge-tools/`) and built by that same `scripts/build-package.sh` (plan §8).*

**Acceptance:** `pacman -U` of the package in a chroot produces a bootable vmlinuz, modules and
DTBs, and `futility show` on the hook's kpart reports `Body verification succeeded`. *Both halves
are verified: `pacman -U` installs over ALARM's `linux-aarch64`, which ours conflicts with, and
`mkinitcpio -P` builds both images from the preset; and `boot/make-kpart.sh` builds the signed FIT
from the built rootfs (30M, lzma, the vendored devkeys) with `futility show` reporting
`Body verification succeeded` (recon §10). Re-verified after the rebuild that added `-headers` back:
the kpart built from that rootfs is 30.2M with `mt8192-asurada-hayato-r1.dtb` first and
`kern_guid=%U quiet loglevel=2 root=UUID=… rootwait rw`, and pacman installs the signed bundle with
`SigLevel = Required DatabaseOptional` (no `TrustAll`). The automatic trigger now exists too (the
ALPM hook above) and was exercised in a chroot; what remains is a boot on hardware, where the hook's
write path runs for real (Phase 7).*

### Phase 2 — Rootfs bootstrap

- [x] `build-rootfs.sh`: bootstrap ALARM aarch64 (a pacstrap-equivalent inside a chroot, or the
      ALARM tarball), then write `pacman.conf` with `[platform]` (local bundle) → `[omarchy]`
      edge/aarch64 → ALARM `core`/`extra`/`alarm`, with the `SigLevel` upstream uses.
      *Verified: the tarball is the bootstrap; a full `-Syu` is needed first because its
      `systemd-resolvconf` pins the systemd it shipped with. `DisableSandbox` is added only when
      the build host lacks Landlock; the keyring is `pacman-key --init` + `--populate archlinuxarm`.*
- [x] Install `packages/base.list` plus `devices/google-asurada/packages.list`, applying
      `aarch64-filter.list` for the drops and substitutions.
- [x] Explicitly **exclude** `limine*`, `linux-omarchy`, `linux-t2`, `snapper`, `btrfs-progs`,
      microcode and every `lib32-*`. *Verified: none installed; only `linux-omarchy-book`
      provides the kernel. `plymouth` is **not** excluded: `omarchy-settings` depends on it
      (docs/recon.md §8), so the package stays installed although nothing in this boot chain
      runs it.*
- [x] Targets: hostname, user with sudo, locale, timezone, NetworkManager, a time sync client, and
      our kernel as the only kernel. *Verified: `asurada`, user `omarchy` in `wheel`, `en_US.UTF-8`,
      `America/Mexico_City`, NetworkManager + systemd-timesyncd + sshd enabled.*

**Acceptance:** a chroot that boots in Phase 5 with the expected package set and no x86 leftovers;
the filter decisions recorded in `docs/recon.md`. *The package set and the absence of the excluded
x86 packages are verified; booting is Phase 5. `linux-firmware`'s x86 vendor splits are kept: the
bootstrap ships the metapackage, no exclude list names them, and a blob whose need only shows on
hardware stays reachable.*

### Phase 3 — Omarchy layer

- [x] Apply `upstream/omarchy/patches/0001-aarch64-google.patch` (see §6) before installing, so the
      machine reports `aarch64-google` and the lifecycle operations exist. *The released
      `omarchy`/`omarchy-settings` predate the platform layer, so the runtime and settings are built
      from the pinned checkout as `omarchy-dev`/`omarchy-settings-dev` (`scripts/build-omarchy.sh`,
      recipes vendored in `upstream/omarchy-pkgs/`), with the `[omarchy]` key trusted from
      `keys/omarchy.gpg`.*
- [x] Install `omarchy`, `omarchy-settings` and `omarchy-nvim`, plus the Omarchy package list, the
      way the ISO does it. *`packages/omarchy.list` is installed explicitly and the desktop set is
      composed from the checkout's own lists (`omarchy-base` + `omarchy-aarch64` + the platform's,
      minus `omarchy-x86_64-only.packages`) in one transaction.* Phase 7 added one package from
      `omarchy-other.packages` to `packages/omarchy.list` — `pipewire-pulse`, which Omarchy's own
      audio and screen-recording commands drive through `pactl` (recon §14); the rest of that list
      stays out for the reasons in §8.
- [x] Run the `install/` phases in the chroot as their installer does, deferring machine-specific
      hardware leaves to first boot when that is what their model expects
      (`/var/lib/omarchy/image/target` with `format=1`, `platform=google`); otherwise run them at
      build time. *`omarchy-apply-system` reports "deferred 54 hardware steps to first boot", and the
      user phase's platform leaf defers the same way.*
- [x] Create the user and run `omarchy-provision-user` for it. *As the user and with
      `--first-install`; that context takes the ISO's offline path, which wants the Node.js tarball
      the ISO bundles in `/opt/packages` (`install/user/mise-work.sh`), so the build fetches the same
      release from nodejs.org with its manifest checksum, stages it, and removes it afterwards.*
- [x] Add §3's pin inside `[options]` —
      `IgnorePkg = linux-omarchy linux-omarchy-headers linux-omarchy-book linux-omarchy-book-headers`
      — after the post-install leaf writes Omarchy's own `pacman.conf` in its place.

**Acceptance:** `omarchy-hw-platform` prints `aarch64-google`, from the manifest and from a
`google,asurada` device tree; `setup-boot`/`update-verify` resolve to `omarchy-google-boot` and stop
at "it is not installed" (exit 3 until the boot package of Phase 5 provides them), while
`setup-system` and `setup-user`
succeed; only `linux-omarchy-book` provides the kernel, `snapper`/`btrfs-progs`/`limine*` are absent,
and `omarchy-version` reports `4.0.0.r7026.g51bfd1d-1`.

### Phase 4 — Device layer (Hayato)

- [x] Firmware: `linux-firmware` for the MediaTek SCP, RTW88/RTW88CE and Realtek Bluetooth pieces —
      add vendor-split packages if ALARM breaks them up. *ALARM splits by vendor: the image carries
      `linux-firmware`, `linux-firmware-mediatek` and `linux-firmware-realtek`, listed both in
      `devices/google-asurada/packages.list` and in the platform's own list.*
- [x] Audio: `alsa-ucm-conf` plus `alsa-utils` so the UCM **boot sequence** runs and the card
      exposes a real sink; `pipewire-alsa` for ALSA-only applications. *The MT8192 card is only
      usable once its UCM `BootSequence` has run, and alsa-lib runs that only on an explicit
      `set _boot`: `alsactl restore` drives it on every card add through alsa-utils'
      `90-alsa-restore.rules`, so installing the package is the whole fix (recon §11) — there is no
      script of ours in that path.*
- [x] Keyboard: `keyd` with our configuration (`Ctrl+Alt` plus the top row for VTs, `Search` plus
      the top row for F1–F10, the `cros_ec_buttons`/jack exclusions **before** the generic
      `k:0000:0000` entry, and the Lock key left alone but bound to the locker via `XF86Sleep`).
      Package it as part of the `google` platform leaf so upstream can take it too. *The map and its
      exclusions are `platform/omarchy-google/etc/keyd/default.conf`, ported verbatim from the
      hardware-verified Debian sibling (its `ORIGINS.md` records what changed); the leaf enables the
      unit, which otherwise ships disabled. The Lock key is left alone so logind keeps suspending on
      it, and no session binding is needed: Omarchy's shell locks the session while it sleeps
      (`omarchy-system-sleep-lock`).*
- [x] Backlight: a udev rule for `brightnessctl` (group `video`, `g+w`) if Arch ships none.
      *Arch's brightnessctl ships no udev or polkit file (checked), so the rule travels with the
      platform package and `setup-system` adds the desktop users to `video`.*
- [x] `zram-generator` (already in Omarchy's own aarch64 list), `wireless-regdb`, journald and
      clock settings. *zram is Omarchy's own (its `omarchy-settings` ships
      `/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf`); `wireless-regdb` is installed and
      the world regulatory domain it starts with is not a failure, NetworkManager narrows it from
      the access point; the package ships a bounded journald drop-in, because the device's flash is
      small and slow; and the clock is systemd-timesyncd, enabled in Phase 2.*
- [x] `/usr/share/omarchy-platform/` — the five files are **flat**, not under a per-platform
      directory (recon §11). *`key-names` ships: Omarchy already binds the XF86 keysyms keyd
      supplies, and this tells the keybindings menu which physical key carries each one.
      `displays.conf` and `audio.json` are deliberately left out until the hardware run shows a
      need — there is no evidence of a second backlight device to prefer or of a node worth hiding,
      and both readers tolerate a missing file.*
- [x] The `omarchy-google` package: it owns those files, the keyd configuration, the brightnessctl
      udev rule and the vendor drop-ins (`/usr/lib/udev`, `/usr/lib/systemd`, …), and its
      `setup-system` leaf (the `aarch64-google` implementation) applies the quirks idempotently.
      *Built by `scripts/build-package.sh` into `[platform]` and signed like everything else;
      `provides=omarchy-platform`, `groups=omarchy-platform-google`, named as upstream's Apple
      implementation names itself, so a merged proposal needs no renames. The boot half is Phase 5's
      `omarchy-google-boot`. It is registered in the vendored patch's
      `install/omarchy-aarch64-google.packages` (the gap recon §11 found) and in the device list, so
      the image installs it.*

**Acceptance:** WiFi, Bluetooth, speaker, suspend on lid/power/Lock key and the backlight keys all
work on the booted image, verified by the hardware run in Phase 7. *What the chroot already proves:
the image installs `omarchy-google` from the signed bundle, `omarchy-lifecycle-dispatch setup-system`
resolves to its entrypoint and enables keyd, adds the desktop users to `video` and writes its
markers under `/var/lib/omarchy-google/`, and a second run changes nothing.*

### Phase 5 — Boot chain

- [x] Port `boot/lib-cgpt.sh`: `parted -s <dev> mktable gpt` first, then `cgpt create` and
      `cgpt add` with the pmbootstrap flags (`-S 1 -T 5 -P 10`), labels for kernel/boot/root,
      128 MiB p1 plus 512 MiB p2 ext4 plus p3 ext4. *Ported, and no longer dead code: it is live on
      the device through `install-kpart.sh`, which sources it for `kpart_fits`, `kpart_verify` and
      the chroot guard. Its disk-writing callers are Phase 6's `write-sd.sh`/`install-emmc.sh`. The
      geometry comes from `deviceinfo` (kpart start/size, boot size, filesystem), so nothing is
      duplicated. *After v0.1.0 it was brought back to pmbootstrap parity with the sibling's later
      fixes: p3 ends 33 sectors before the end of the device instead of 2048, a partition that is
      mounted is refused instead of silently mishandled (`findmnt -rn -S <device>`, never
      `mountpoint -q <device>`, which a device node never satisfies), `mkfs` gets `-q`, `partprobe`
      runs after the `cgpt add`s, the partition below 512 MiB is refused and the fstab uses
      pmbootstrap's options. Rehearsed on a loop device and by building an image from a fixture
      rootfs (recon §12). None of this is in v0.1.0: `boot/` ships inside `omarchy-google-boot`, so
      that package needs a rebuild — and a `pkgrel` bump before it is republished (plan §3 decision
      7) — before a device gets it.*
- [x] Port `boot/make-kpart.sh`: `depthchargectl build --board mt8192`, the vboot developer keys,
      hayato's DTB first, no duplicated `kern_guid`, a silent-by-default command line with a
      `KERNEL_CMDLINE_OVERRIDE` escape hatch for verbose boots. *Ported and verified from a built
      rootfs: 30.2M, lzma, `mt8192-asurada-hayato-r1.dtb` first, the vendored devkeys passed
      explicitly, and `futility show` reporting `Body verification succeeded`. The device runs the
      same file: on the device it sources the packaged device-side lib instead of the build host's
      (`boot/lib.sh` here is a wrapper around `scripts/lib.sh`), which is what the package's tests
      compare (recon §12).* *Its command line is joined with an explicit separator since the parity
      pass (`printf '%s %s' … | tr -s ' ' | sed`): `tr '\n' ' '` over `kernel-cmdline.conf` produces a
      separator only when that file ends with a newline, and without one `root=UUID=…` would be glued
      to the last option — measured, and latent here only because the file does end with one (recon
      §12).*
- [x] Kernel command line from `devices/google-asurada/kernel-cmdline.conf` plus `root=UUID=…`
      resolved from the built rootfs, the way `debian-aarch64` resolves it. *Verified in the kpart
      that was built: `kern_guid=%U quiet loglevel=2 root=UUID=… rootwait rw` — the file carries
      `quiet`/`loglevel=2`, and the GUID and the root UUID are appended by the caller (on the
      device `install-kpart.sh` reads the UUID with `findmnt`/`blkid`; for an image it comes from the
      built rootfs). `KERNEL_CMDLINE_OVERRIDE` is the verbose escape hatch.*
- [x] An `install-kpart.sh` equivalent, with backup and `CONFIRM=yes`. *`boot/install-kpart.sh`,
      shipped in `omarchy-google-boot` and reachable as `omarchy-google-boot setup-boot` and
      `kpart-rewrite`. It resolves p1 from `kern_guid`, refuses a partition that is not a ChromeOS
      kernel partition, builds the FIT from the running system (`ROOTFS=/`,
      `KERNEL_RELEASE=$(uname -r)`), checks that it fits and verifies, backs the old p1 up to
      `/var/lib/omarchy-google-boot/` before writing, and re-reads the result with `futility show`.
      Without `CONFIRM=yes` it prints the plan and stops. The write itself is Phase 7; off-device it
      is refused by the chroot guard, which is verified (recon §12).*

**Acceptance:** the card boots with Ctrl+U (`crossystem dev_boot_usb=1 dev_boot_signed_only=0`), and
`futility show` on p1 reports a dev-signed FIT. *Everything short of the boot is verified in a
chroot: the dispatcher resolves the operations to the package's entrypoints, the FIT builds and
verifies, the ALPM hook fires and skips safely, and the guard refuses a chroot. Booting the card is
Phase 7's.*

### Phase 6 — Image, release, install, backup

- [x] `make-image.sh` on a loop device (size as `IMAGE_SIZE_MIB`) and `make-release.sh` producing
      an `.img.xz`, a rootfs tarball, a `vmlinuz.kpart` and `SHA256SUMS`. *`scripts/make-image.sh`
      and `scripts/make-release.sh`; the release also carries `platform/` (the bundle as a
      repository), `RELEASE-INFO.txt` (commit, dirty flag, tag, kernel, Omarchy pin, bundle hashes,
      bootstrap tarball hash) and two `SHA256SUMS`. `SIZE_MIB` defaults to the rootfs size plus
      12.5% and a quarter GiB, rounded up to 256 MiB: an Arch + Omarchy install is ~9 GiB, where
      Debian's fixed 4 GiB would die mid-copy. Rehearsed end to end against a fixture rootfs
      (recon §13). *v0.1.0 then built it for real and priced it: ~25 GiB of working disk, because
      the rootfs, the image and `lib-dist`'s staging copy exist at once, and the image and the
      tarball come out over the 2 GiB a file in a GitHub release may be, so both ship as parts cut
      at 1800 MiB, with `SHA256SUMS` over the whole file as the check (recon §13).*
- [x] A `lib-dist.sh` equivalent: never publish straight out of `$ROOTFS` (Wi-Fi PSKs, SSH host
      keys, machine-id); sanitize a copy and assert it clean. *`scripts/lib-dist.sh`. The paths are
      excluded from the copy and the finished artifact is byte-searched for the profiles' SSIDs and
      PSKs, because deleting a file after copying it leaves its bytes in the image's free blocks —
      the measurement that shaped the Debian original. Added over it: the *build-state* rules this
      port needs (the build-time `/packages` bundle, the bind-mounted pacman cache, the build's own
      logs, `/tmp` and `/var/tmp`) and a fatal finding for any `/home/<name>` with no account
      (recon §13). Tested with decoys: a planted profile is found and publication is refused.*
- [x] Image hygiene from what Phase 4's verification turned up: ALARM's own `alarm` account
      (uid 1000, in `wheel`, with a password set) travels in the tarball and must not reach a
      release. Lock or delete it, and sweep for anything else the ALARM bootstrap leaves behind
      before `make-release.sh` publishes (Phase 7's `check-system.sh` should assert it).
      *Decided 2026-10-17, having weighed locking and deleting it: **the account stays and the risk
      is documented instead** — the build does not touch it (this port's user is `omarchy`), a
      published image keeps ALARM's account as ALARM ships it, and `make-release.sh` prints a
      warning naming every account with a password (`root`, from ALARM's tarball, included) so it
      cannot be published unnoticed. The residual risk is a known password on a wheel account if a
      machine is reachable before the passwords change; the release notes carry it and Phase 7's
      `check-system.sh` asserts it. The sweep for everything else is done (above and recon §13).*
- [x] An upgrade path for the bundle. The image configures no `[platform]` repository, so neither
      `linux-omarchy-book` nor `omarchy-google` can ever be updated on a device (recon §9); decide
      whether a release publishes the bundle as a repository the image trusts, and give a
      republished package — same version, new bytes, because a recipe or the vendored patch changed —
      a version bump so an installed machine can actually move to it. *Decided: a release publishes
      the bundle as a repository (`make-release.sh` writes `platform/`: the signed packages and
      their `.sig`, the database `repo-add` built during the image build, `platform.pub` and a
      README) and the image takes a `[platform]` section pointing at it when `PLATFORM_REPO_URL` is
      set — a build input in `scripts/lib.sh`, empty by default so an unreleased build still carries
      no repository it could fail to reach. The trust is already in place: every image trusts the
      bundle's signing key. A package that a release already carries gets a `pkgrel` bump before it
      is republished (the content-addressed republish the build stamps use stays for build-internal
      rebuilds), because pacman only moves forward on a version change (recon §9).*
- [x] `write-sd.sh`, `install-emmc.sh` (rsync the running system onto `/dev/mmcblk0`, refusing the
      internal disk from the SD writer and the running root from either) and `install-kpart.sh`.
      *All three in place (`install-kpart.sh` since Phase 5, from `boot/`). `write-sd.sh` and
      `install-emmc.sh` live in `scripts/` and source `boot/lib-cgpt.sh`, the single copy of the
      layout, which the boot package ships to the device. Both refuse `mmcblk0`, zram, the running
      root and the disk carrying `$WORK_DIR` (on this hardware the build host *is* the device, so
      those are the same disk). `write-sd.sh` is rehearsed on a 2 GiB loop: three partitions,
      correct fstab, a 30 MiB FIT in p1 that `futility show` accepts (recon §13).*
- [x] `backup-system.sh` and `restore-system.sh` ported from the working pair: raw GPT dumps, the
      kpart resolved from `kern_guid`, filesystems as tars, SHA256SUMS verified before writing,
      UUIDs taken from the archive's own `/etc/fstab`, refusing a differently sized disk, root-only.
      *Both in `scripts/`. `backup-system.sh` runs on the host and writes the two GPT areas, the
      p1 dump, two gzip tars, a transcript and a README that carries the restore instructions.
      `restore-system.sh` was rehearsed on a loop device with exactly the same sector count as its
      synthetic backup, with `DEEP=yes` and independently of the repository's own layout (UUIDs
      from the archive's fstab): the GPT compares byte for byte, both filesystems take the original
      UUIDs, `tar -d` agrees, and the five refusals hold (size, partition, not a block device, no
      `CONFIRM=yes`, tampered `SHA256SUMS`). `backup-system.sh` also refuses to run from a chroot —
      new here, and not in the Debian original (recon §13).*

**Acceptance:** a release built from a committed HEAD only; a card written from that image boots;
`restore-system.sh` rehearsed on a loop device with exactly the same sector count. *The first is
enforced by `make-release.sh` (a dirty tree is refused; `ALLOW_DIRTY=yes` is the rehearsal escape
hatch) and recorded in `RELEASE-INFO.txt`. The third is done (recon §13). Booting the card is
Phase 7's, on hardware.*

### Phase 7 — Hardware validation

- [x] Port `check-system.sh` to Arch and add the Omarchy-specific checks: `omarchy-hw-platform`
      prints `aarch64-google`; Hyprland starts on Mesa/Panfrost; the Quickshell session comes up;
      the audio profile is not `off` and there is no *Dummy Output*; the keyd mapping and the Lock
      key both behave; the brightness keys work as the desktop user; `linux-omarchy` is absent and
      `linux-omarchy-book` installed; p1 holds a signed FIT. **Done:** `scripts/check-system.sh`,
      with each check mapped to a measurement in recon §14 and the port's own decisions; it also
      carries the first-boot manifest checks (a first boot that half-finishes is invisible
      otherwise) and the FIT's `root=UUID=` against the running root. The package, file and
      configuration half is exercised against the built rootfs (chroot rehearsal with the repository
      bind-mounted: 39 ok, 6 warn, 0 FAIL, 13 skip), and the live half stands down off a real boot
      (chroot, or the sandboxed shell this repository is developed in), so what Phase 7 adds is its
      output on hardware.
- [x] Store the output in `reports/`, one file per boot worth keeping. **Six files, three cards**
      (2026-10-17). The first card: `2026-10-17-first-boot.txt` (95 ok, 3 warn, 2 FAIL, 2 skip — run
      from tty1, so the two session checks are the skips) and its `2026-10-17-diagnostics.txt`. The
      second card: `2026-10-17-first-boot-second-card.txt` (104 ok, 2 warn, 3 FAIL, 0 skip — run
      from the desktop session) and `2026-10-17-diagnostics-second-card.txt`. Every FAIL and warn is
      mapped in recon §14. The first card's mapping closed three: ufw needs netfilter matches the
      kernel was not building, the greeter can never log in without `/var/lib/sddm/state.conf`
      (upstream writes it when it creates the owner at first boot; this port ships the owner in the
      image, so the image writes it), and the `[platform]` key the build lsigns is replaced by the
      first boot's own `pacman-key --populate` unless it is shipped as a keyring; its swap FAIL was
      the check's, `test -s` on a procfs file, which is false with zram active (recon §14). The
      second card's report shows all three fixed from the desktop -- SDDM logs in, Hyprland runs,
      `ufw is active`, keyd has its virtual keyboard, the `[platform]` key is trusted -- and its own
      three FAILs are one cause: the user's home was never seeded from `/etc/skel` (no Omarchy
      Hyprland config, so no shell, no sleep monitor and no user units; fixed in `build-rootfs.sh`).
      The third card, written with that fix, is `2026-10-17-first-boot-third-card.txt` plus
      `2026-10-17-diagnostics-third-card.txt` (108 ok, 1 warn, 1 FAIL, 0 skip): the shell running,
      Omarchy's configuration in place, the sleep lock enabled, the swap up a second after boot, and
      both its warn and its FAIL were the report asking the wrong question (`pgrep -x` against a name
      the kernel truncates to 15 characters, an assumption about who made a Wi-Fi profile), fixed
      with the count that read only a JSON's last line. A re-run of that report is the acceptance's.

**Acceptance:** a report from a booted card with no FAIL, and every FAIL mapped to a known
regression rather than a hypothetical. *The three cards above are what the mapping is made of. The
third card's every line is mapped now, including the three that turned out to be the report's own
probes, so its re-run -- the card is still booted, the check reads only -- is the report the
acceptance asks for.*

### Phase 8 — Upstream proposal

- [ ] `docs/upstream.md`: the `aarch64-google` proposal — detection change, lifecycle operations,
      package list, platform data — with its reasoning and the hardware it was verified on.
- [ ] A PR to `omacom/omarchy` (detection, dispatch, `install/hardware/google/*`,
      `install/omarchy-aarch64-google.packages`, `/usr/share/omarchy-platform/*` owned by
      `omarchy-google`) and, if the manifests need it, one to `omacom/omarchy-iso` adding `google` as
      a platform name.
- [ ] Once merged, delete the vendored patch: the repository keeps building from stock Omarchy.

---

## 6. The upstream proposal in detail

Design constraints that make this upstreamable rather than a fork:

- **`google,` is a device-tree vendor prefix**, exactly like `apple,` and `qcom,` — the detector's
  own rule ("only a token's vendor prefix counts") already supports it.
- **Board identity stays out of the platform code.** A Chromebook answers `kern_guid` in its own
  command line, so a generic `setup-boot` can resolve the kernel partition the same way
  `install-kpart.sh` does, and read the board from the device tree `compatible` to pick
  `--board <board>` for `depthchargectl`. Nothing Google-specific is hardcoded.
- **The kernel is not part of the proposal.** It travels as a `[platform]` bundle, which is what
  that repository exists for ("pins a kernel under test and anything held at a version proven on the
  hardware").

Patch surface:

| File (repo `omarchy`) | Change |
|---|---|
| `bin/omarchy-hw-platform` | recognise `google,` → `aarch64-google`; add `aarch64-google` to the allowed-platform regex; add a `google` name to the image-manifest mapping |
| `bin/omarchy-lifecycle-dispatch` | register the `aarch64-google` operations: `setup-boot`, `setup-system`, `update-verify`, `post-install`, and whatever Phase 0 shows is mandatory |
| `install/hardware/google/` | `boot.sh` (ChromeOS GPT plus the signed kpart, resolved from `kern_guid` and the device tree), `firmware.sh` (MediaTek/RTW88), `keyboard.sh` (keyd), `audio.sh` (UCM) |
| `install/omarchy-aarch64-google.packages` | `cgpt`, `vboot-utils`, `depthcharge-tools`, `keyd`, `alsa-ucm-conf` and friends, named like `omarchy-aarch64-apple.packages` |
| `/usr/share/omarchy-platform/` | flat, owned by `omarchy-google`: `displays.conf`, `audio.json`, `key-names` (no per-platform subdirectory — recon §11) |

While the PR is open the patch lives in `upstream/omarchy/patches/` with a `series` file and is
applied by `build-rootfs.sh`. The patch *is* the proposal, so the two cannot drift.

---

## 7. Risks and traps

| Risk | Mitigation |
|---|---|
| **Registering `aarch64-google` requires every lifecycle operation** the dispatcher calls; an unimplemented `reset-*` may fail loudly | Phase 0 answers this before any code is written; if it errors, implement them as explicit no-ops with a message, or stay on plain `aarch64` plus our own package until upstream agrees |
| 4 GB RAM, Quickshell plus Hyprland on Mali-G57 | 1920×1200 at scale 1 should be comfortable; measure, and if needed trim the shell's heavier pieces rather than the compositor |
| `chromium` on ARM (a known weak spot) | `brave-bin` **is** published for aarch64; keep Chromium optional |
| `omarchy update` pulling `linux-omarchy` back in | `provides`/`conflicts`, `IgnorePkg` and the hook; verify after an update in Phase 7 |
| AUR/ALARM build tooling (`depthcharge-tools` in AUR, `vboot-utils` in ALARM) and missing devkeys | `vboot-utils` (ALARM `alarm` repo) provides `cgpt`+`crossystem`+`futility` but **no keys**: vendor `boot/devkeys/`. `depthcharge-tools` is an AUR `arch=any` Python package. Build/publish both into our `[platform]` bundle |
| `depthcharge-tools` system hooks guessing a kernel partition inside a chroot | Disable them exactly as the Debian port does, and rely on our own explicit hook |
| No LUKS, therefore no factory-reset or re-key path | Declared a non-goal; revisit only if the kpart command line and initramfs can unlock it cleanly |
| Omarchy assumes a keyboard with Super and F-keys; its `fix-fkeys.sh` only sets `hid_apple fnmode=2` | Our keyd configuration in the platform leaf; `Search` already is Super on this machine |
| Edge channel moving under us | Record the verified versions in `docs/recon.md`; hold nothing but the `linux-omarchy*` packages (the simplest policy that stays safe) |
| Package `omarchy`/`omarchy-settings` depending on the upstream kernel | `provides=('linux-omarchy')` plus `conflicts=('linux-omarchy')` on `linux-omarchy-book`; confirmed in Phase 0 |

---

## 8. Open questions

Resolved:

1. Kernel package name: **`linux-omarchy-book`** and `linux-omarchy-book-headers`.
2. Channel policy: **the simplest safe one** — no snapshot and no mirror of `[omarchy]`, just
   `IgnorePkg` for `linux-omarchy*` and the verified versions recorded in `docs/recon.md`.

Still open:

3. Whether LUKS is wanted later; it changes the kpart command line and the initramfs hooks.
4. Whether the SD-installed card must be able to install to eMMC on its own (as in
   `debian-aarch64`) — assumed yes.
5. **Resolved**: the recipe for an AUR-only *device* package lives in
   `upstream/depthcharge-tools/`, next to the vendored Omarchy recipes and with a
   `PROVENANCE.md` of its own, and `scripts/build-package.sh` builds it into
   `[platform]` (verified: it is what published the signed 0.6.2-1 in the
   bundle). `depthcharge-tools` had been built by hand, so a clean `$BUILD_ROOT`
   could not rebuild the bundle it installs the device from.

## 9. First commits once the agent switches

1. `git init` in `~/Dev/omarchybook`, `README.md`, `AGENTS.md` and `.gitignore`.
2. `docs/plan.md` (this document) and `docs/recon.md` (the evidence already gathered in §2).
3. `devices/google-asurada/` — `deviceinfo` translated, `kernel-cmdline.conf`, `modules-initfs`,
   `packages.list` and `PROVENANCE.md`. The platform implementation is *not* here but in
   `platform/omarchy-google/` (Phase 4): it is keyed to the `google` family, not to this board.
4. `kernels/mediatek-mt81/` vendored with its `version`, `config.aarch64` and `patches/series`,
   with a provenance note pointing at `debian-aarch64`.
5. `boot/lib-cgpt.sh`, `boot/make-kpart.sh` and `boot/install-kpart.sh` ported, with the
   `boot/lib.sh` wrapper that lets the packaged copies find their configuration on a device.
6. `upstream/omarchy/patches/0001-aarch64-google.patch` as a skeleton, plus `series`.

Then Phase 0, whose answers may still change the patch skeleton before anything is built.

