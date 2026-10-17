# Recon (Phase 0)

Evidence gathered for the port: commands and their outputs, not narrative. Phase 0 is
read-only. `docs/plan.md` holds the plan; this file holds the proof and the pinned versions
(the pinning policy is `IgnorePkg` for `linux-omarchy*` plus these versions, plan §3).

Environment: aarch64 host, `2026-10-16`.

## Pinned upstream snapshots

| Repo (`omacom/`) | Branch | Commit | Notes |
|---|---|---|---|
| `omarchy` | `quattro` | `51bfd1d` | working tree says `version` = `4.0.0.alpha`; the published package is `4.0.4-2` |
| `omarchy-pkgs` | `master` | `aad6d43` | PKGBUILDs; builds run in Docker/Podman |
| `omarchy-iso` | `quattro` | `43cf049` | image builder, pacman configs, `aarch64-package-filter.sh` |
| `[omarchy]` `edge/aarch64/omarchy.db` | — | 2026-10-16 | **197 packages** (`omarchy.db` downloaded and extracted) |
| `chromiumos/vboot_reference` | — | `10343b821` (`r2729.10343b821`) | developer keys vendored into `boot/devkeys/`; the revision ALARM's `vboot-utils` is built from |

Recon checkouts live in `$HOME/.cache/omarchybook-recon/` (not part of the repo).

## 1. Hardware platform detection

`bin/omarchy-hw-platform` is `bash -p`; it refuses a plain `bash script` launch (needs the `-p`,
i.e. run it directly through its shebang). It reads the device-tree root `compatible` and **only
a token's vendor prefix counts**.

```sh
mkdir -p /tmp/fix/device-tree && printf 'google,asurada' > /tmp/fix/device-tree/compatible
OMARCHY_PROC_ROOT=/tmp/fix ./omarchy-hw-platform   # -> aarch64
```

Confirmed: a `google,` prefix resolves to plain **`aarch64`** today — no error, no family. The
final `case` maps only `apple,*` and `qcom,*`; everything else on an ARM CPU is `aarch64`.

Also relevant: an image manifest (root-owned regular file, `format=1`) can pin the platform, with
`apple-silicon|generic-aarch64|generic|qualcomm` mapped to the family names; the allowed-platform
regex is `^(x86|aarch64|aarch64-apple|aarch64-qualcomm|aarch64-n1x|aarch64-gb10)$`.

## 2. Lifecycle dispatch (`bin/omarchy-lifecycle-dispatch` + `docs/lifecycle-dispatch.md`)

**Registration is code, not configuration.** The fixed operation set:

```
provision-prepare provision-commit provision-verify
reset-prepare reset-verify reset-commit reset-rollback
update-verify update-takeover
luks-slots
setup-boot setup-system setup-user
post-install pre-remove
```

`user_operations = setup-user post-install pre-remove` (run as the user; refused as root when the
platform registers them).

**Answer to the Phase 0 question — unimplemented operations do not have to exist, we choose the
contract:** the `case $platform:$operation` block ends in `*) exit 0`, so every platform except
`aarch64-apple` is a no-op for every operation. When we add an `aarch64-google` case we declare,
per operation:

- **required**: a missing entrypoint is `exit 3` (package not installed) or, if the pacman record
  shows the package installed, `exit 1` ("update the package").
- **optional**: a missing entrypoint is `exit 0` (no-op).

So the plan §7 risk is controllable: `aarch64-google` must list as `required` only the operations
it actually ships, or implement the rest as explicit entrypoints. Upstream's own note: moving an
operation to required also changes `apple_optional` in
`test/shell.d/lifecycle-dispatch-test.sh` and the registration table in `docs/lifecycle-dispatch.md`.

Entrypoint rules (enforced, and re-checked by anything that can run them directly): a regular
executable file, no symlinks in the path up to `/`, root-owned, not writable by group/other; it
runs with an empty environment except `PATH=/usr/local/sbin:/usr/local/bin:/usr/bin`.

### Where `setup-boot` / `setup-system` run

`install/hardware/platform-setup.sh` is the **last leaf** of `install/hardware/all.sh`; it runs
`setup-boot` then `setup-system`. In a prebuilt image the leaf is queued and runs on the machine's
**first boot** via `omarchy-provision-hardware` with `OMARCHY_IMAGE_DEFERRED_HARDWARE=1`, which the
leaf passes on as `image-first-boot`. In that mode an operation should **ask** for a boot-file
rebuild by creating `/var/lib/omarchy/image/boot-rebuild` rather than building one (the first boot
may be offline). In a normal ISO install the same leaf runs in the install environment. Our "build
away from the device" model uses the first-boot path.

Platform hardware description files live in the fixed **`/usr/share/omarchy-platform/`** root
(`display.conf`/`displays.conf`, `key-names`, `audio.json`, keyrings, camera cutouts). Only the one
installed platform package owns the root; Omarchy ships nothing there; a missing root or file means
no additions. For us this is `/usr/share/omarchy-platform/google/`.

Platform package-list convention: `install/omarchy-<platform>.packages`, e.g. `omarchy-aarch64.packages`,
`omarchy-aarch64-apple.packages`, `omarchy-aarch64-qualcomm.packages`. Ours would be
`install/omarchy-aarch64-google.packages`. Apple's implementation dirs are `/usr/lib/omarchy/mac-boot`
(package `omarchy-mac-boot`, its boot operations) and `/usr/lib/omarchy/mac` (package `omarchy-mac`,
`setup-system`/`setup-user`/`post-install`/`pre-remove`) — the model for `google-boot` / `google`.

## 3. Do `omarchy` / `omarchy-settings` depend on `linux-omarchy`? — **No**

From the `[omarchy]` `desc` files:

- `omarchy-4.0.4-2` DEPENDS: `omarchy-keyring`, `omarchy-settings=4.0.4`, `hyprland`, `quickshell`,
  `uwsm`, `sddm`, `xdg-desktop-portal-hyprland`, `wireplumber`, `pipewire`, `gnome-keyring`, `gum`,
  `jq`, `git`, `perl`, `fakeroot`, `pacman-contrib`, `ttf-jetbrains-mono-nerd-basic`,
  `networkmanager`. **No `linux-omarchy`.**
- `omarchy-settings-4.0.4-6` DEPENDS: `bash`, `curl`, `gum`, `hicolor-icon-theme`, `plymouth`;
  optional deps `omarchy`, `inxi`, `fastfetch`. **No `linux-omarchy`.**

`linux-omarchy` only depends on its own `linux-omarchy-bore`/`-headers` (meta package, see §6).
Pinning stays `IgnorePkg=linux-omarchy*` plus `provides`/`conflicts` on `linux-omarchy-book`.

## 4. `[omarchy]` aarch64 package set (edge)

197 packages. Present and relevant (versions as of the snapshot):

| Package | Version |
|---|---|
| `omarchy` | 4.0.4-2 |
| `omarchy-settings` | 4.0.4-6 |
| `omarchy-nvim` | 2026.9.21-5 |
| `quickshell` | 0.3.2-6 |
| `hyprland` | 0.56.2-7 |
| `aquamarine` | 0.15.1-1.3 |
| `mise-bin` | 2026.10.11-1 |
| `yay` | 13.0.1-1 |

Absent from `[omarchy]` (come from ALARM): `uwsm`, `sddm`, `nvim` (ALARM still ships Neovim as
`neovim`; `aarch64-package-filter.sh` maps `nvim`→`neovim` and `vi`→`ex-vi-compat`).
`[omarchy]` does **not** carry `keyd`, `alsa-*` or `linux-firmware` (expected — those are ALARM).

## 5. Arch Linux ARM from Omarchy's mirror

Server pattern `https://arm-mirror.omarchy.org/$arch/$repo` (`pacman-online-aarch64.conf`); precedence
`[platform]` (local bundle) → `[omarchy]` → `core`/`extra`/`alarm`/`aur`. `arm-mirror.omarchy.org/aarch64/$repo/$repo.db` returns 200.

Verified available (repo, version):

| Package | Version | Repo |
|---|---|---|
| `keyd` | 2.6.0-5 | extra |
| `alsa-ucm-conf` | 1.2.16.1-1 | extra |
| `alsa-utils` | 1.2.16-1 | extra |
| `mesa` | 1:26.2.4-1 | extra |
| `chromium` | 153.0.8010.36-1 | extra |
| `zram-generator` | 1.2.1-1 | extra |
| `wireless-regdb` | 2026.09.03-1 | core |
| `uwsm` | 0.27.1-1 | extra |
| `sddm` | 0.21.0-7 | extra |
| `pipewire-alsa` | 1:1.6.9-1 | extra |
| `brightnessctl` | 0.5.1-3 | extra |
| `networkmanager` | 1.58.1-2 | extra |
| `linux-firmware` | 20260916-1 | core |
| `base` / `pacman` / `mkinitcpio` | 3-3 / 7.1.0.r9.g54d9411-3 / 42.2-1 | core |
| `linux-aarch64` (ALARM kernel, **not ours**) | 7.2.10-1 | core |

**`linux-firmware` is split by vendor in ALARM core.** The MediaTek SCP and the RTW88/Realtek
Bluetooth pieces are in `linux-firmware-mediatek` and `linux-firmware-realtek` respectively (base
`linux-firmware` plus 20 vendor packages exist). Device `packages.list` must pull those two in
(plan §4 explicitly anticipated this). `mise` is `mise-bin` in `[omarchy]`, not ALARM.

## 6. Upstream kernel recipe (template for `linux-omarchy-book`)

`omarchy-pkgs/pkgbuilds/linux-omarchy/PKGBUILD` (master) is now a **meta package**: `pkgbase=linux-omarchy`
with `linux-omarchy` + `linux-omarchy-headers` depending on `linux-omarchy-bore(-headers)`, and its
`arch=(x86_64)` field is x86-only. The `[omarchy]` repo publishes `linux-omarchy-7.2.8-11` for
aarch64. So the recipe is a template for the packaging conventions and dependency shape, not a
drop-in; our `linux-omarchy-book` is its own PKGBUILD (plan §3, Phase 1).

`omarchy-iso/builder/linux-omarchy.preset` is the mkinitcpio preset shape to model on (one `archiso`
preset, `ALL_kver=/boot/vmlinuz-linux-omarchy`, `archiso_image=/boot/initramfs-linux-omarchy.img`).

`omarchy-iso/builder/aarch64-package-filter.sh` is the closed x86→arm list: `linux|linux-omarchy|linux-t2`
→ platform kernel, `*-headers` likewise, `nvim`→`neovim`, `vi`→`ex-vi-compat`, `obs-studio`/`yay-debug`
excluded (not published for aarch64), plus an explicit x86-only exclusion list. Anything not listed
and missing fails the build. It is invoked as `filter_aarch64_packages <kernel> <packages...>`.

## 7. Boot tooling from the AUR (built natively, published into `[platform]`)

- **`depthcharge-tools` 0.6.2-1**, `arch=('any')`, depends `python`, builds with `python setup.py
  install`. Provides `depthchargectl` / `mkdepthcharge`. The **Debian package's kernel/initramfs
  hooks are what had to be disabled** in `debian-aarch64`. **Confirmed after a native build in the
  ALARM chroot**: the package ships only `/usr/bin/depthchargectl`, `/usr/bin/mkdepthcharge` and
  `usr/lib/python3.14/site-packages/depthcharge_tools/` — **no `/etc/kernel/postinst.d`,
  `/etc/initramfs/post-update.d` or libalpm hooks**, so nothing to disable on Arch. (The AUR
  PKGBUILD also forgets `python-setuptools` as a makedepend; the build fails without it, and the
  vendored copy adds it — as a makedepend only. The recipe needed three more fixes to run at all on
  python 3.14; they are in the vendored copy and explained in §12.) **The recipe is vendored** in
  `upstream/depthcharge-tools/` (AUR commit
  `9f20e678ed63f4b9f20e82ace555577c0c88c7b5`, PKGBUILD SHA-256 recorded in its `PROVENANCE.md`) and
  built by `scripts/build-package.sh`, the generic builder every recipe goes through: a clean
  `$BUILD_ROOT` reproduces the bundle now (see §10).
- **`vboot-utils`** exists in two places and they are not equivalent:
  - **Arch Linux ARM's `alarm` repo** (not the AUR): `vboot-utils r2729.10343b821-1`, package file
    `*.pkg.tar.xz` (not `.zst`). Downloaded and listed: it installs `usr/bin/cgpt`,
    `usr/bin/crossystem`, `usr/bin/futility`, `vbutil_*`, and `provides = cgpt`. It ships **no
    `/usr/share/vboot/devkeys`** — so the keys must be vendored (`boot/devkeys/`, plan §4).
  - **AUR `vboot-utils` 154.16805-1**: `arch=(i686 x86_64)`, builds vboot from source, and its
    PKGBUILD does install `/usr/share/vboot/devkeys`. It is x86-only in the recipe; a native aarch64
    build would need `makepkg --ignorearch`. Prefer the ALARM package and vendor the keys.
- **`vboot-kernel-utils` is not in the AUR.** On Arch, `cgpt` **and** `futility` both come from
  `vboot-utils` (ALARM), unlike Debian where `cgpt` and `vboot-kernel-utils` are separate packages.
- **Which tool takes which key option** (`depthcharge-tools` cloned, HEAD `1c123c8`; verified against
  both the built 0.6.2 and the host's 0.6.3): the *default* search order (`config.ini` +
  `utils/platform.py`) is `/etc/depthcharge-tools`, `/usr/share/vboot/devkeys`,
  `/usr/local/share/vboot/devkeys`, for the names `kernel.keyblock`, `kernel_data_key.vbprivk`,
  `kernel_subkey.vbpubk`. **`depthchargectl` has no `--keydir`** — that option is `mkdepthcharge`'s
  (`--keydir`, plus `--keyblock`/`--signprivate`/`--signpubkey`); `depthchargectl build` takes the
  three files as `--vboot-keyblock`, `--vboot-public-key` and `--vboot-private-key`.
  `boot/make-kpart.sh` passes those three explicitly, which is what makes the vendored
  `boot/devkeys/` actually used (it originally passed `--keydir` and every kpart build failed with
  `unrecognized arguments`).

Everything AUR-only that is needed on the device gets built once and published into the local
`[platform]` bundle (`repo-add`), per plan §7.

## 8. The Omarchy layer (Phase 3)

**The released packages cannot carry the patch.** `[omarchy]`'s `omarchy-4.0.4-2` and
`omarchy-settings-4.0.4-6` are built from `basecamp/omarchy` at the `v4.0.4` tag
(`_commit=c668141`), whose tree has **no** `bin/omarchy-hw-platform`,
`bin/omarchy-lifecycle-dispatch` or `bin/omarchy-pkg-defaults` — the platform layer this port
patches. `git apply` of the proposal against that tree fails on four files. The layer exists only
on the `quattro` tip (`51bfd1d`), so the runtime and settings are built here from that checkout.

**The recipes for that already exist.** `omarchy-pkgs` ships `pkgbuilds/omarchy-dev` and
`pkgbuilds/omarchy-settings-dev`, pinned to `pkgver=4.0.0.r7026.g51bfd1d` /
`_commit=51bfd1d`, with `provides`/`conflicts` against the released names and an `OMARCHY_SRC`
hook that builds from a local tree — the same mechanism the ISO uses with `--local-source`.
Vendored under `upstream/omarchy-pkgs/` and driven by `scripts/build-omarchy.sh`; the runtime
depends on `omarchy-settings-dev` and on `omarchy-security-functions` (both satisfied by the
settings package) and on `omarchy-themes-intros` (from `[omarchy]`).

**`omarchy-other.packages` is not the target set.** Its own header says it exists so the ISO's
offline mirror holds every package any machine might need (x86, Apple, NVIDIA, Intel). The set a
machine installs is `omarchy-base.packages` + `omarchy-aarch64.packages` + its platform's
`omarchy-aarch64-<platform>.packages`, minus `omarchy-x86_64-only.packages` (empty at this pin) —
which is exactly what `omarchy-pkg-defaults` composes at runtime and what `build-rootfs.sh`
composes from the checkout at build time.

**`plymouth` is a hard dependency of the settings package.** `omarchy-settings-dev` lists it in
`depends`, so excluding it leaves an unsatisfiable transaction. It stays installed; the HOOKS
change below is what keeps it out of the initramfs.

**`linux-modules-cleanup.service`, which `install/config/enable-services.sh` enables, is shipped
by ALARM's `kernel-modules-hook`** (extra), and that package is in `omarchy-base.packages`
(recon of the gzipped `extra.files`: `kernel-modules-hook-0.1.7-3-any` → `usr/lib/systemd/system/linux-modules-cleanup.service`).
It is **not** in the bootstrap tarball or ALARM's kernel, so the enabled unit only exists once the
Omarchy set is installed.

**The non-Apple HOOKS baseline does not fit this boot chain.** `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf`
sets `HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)`
for every platform that is not a Mac. `btrfs-overlayfs` is not even shipped by ALARM's `mkinitcpio`
(`usr/lib/initcpio/install/` has no `btrfs-overlayfs`), `plymouth` and `encrypt` are unused here,
and the kernel partition is not an ESP. The proposal therefore folds `aarch64-google` into the
existing `platform-owned` case, leaving `HOOKS` to `/etc/mkinitcpio.conf` (ALARM ships
`base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck`, the
set Phase 1 verified builds).

**Build-time gotchas.** pacman's `CheckSpace` cannot resolve a chroot's root mount point on this
build host ("could not determine root mount point /"), so `scripts/build-omarchy.sh` disables it
in its throwaway build chroot. `makepkg` needs `--nodeps`: the runtime depends on the whole
desktop (hyprland, quickshell, sddm…), which is not installed in a packaging chroot, and the
recipes only copy files.

**The final `/etc/pacman.conf` is Omarchy's template, and it has no `[platform]`.** The last
post-install leaf copies `default/pacman/aarch64/pacman-edge.conf` and `mirrorlist-edge` over the
build-time configuration, so the image ends up with `[omarchy]` → `core`/`extra`/`alarm`/`aur`
via `https://arm-mirror.omarchy.org`, and the local `file:///packages` bundle is dropped — which is
right (a device should not carry a build-time repository) but means the kernel is no longer
upgradeable from a configured repo. Providing the device a `[platform]` repository (or a signed
bundle it can re-index) is Phase 1's remaining publication item meeting Phase 4's device work.

It carries no `IgnorePkg` either, although plan §3's pinning policy is nothing but that. So
`build-rootfs.sh` adds
`IgnorePkg = linux-omarchy linux-omarchy-headers linux-omarchy-book linux-omarchy-book-headers`
inside `[options]` right after that leaf runs (`pacman-conf IgnorePkg` confirms the file parses).
Pinning this port's own kernel too is deliberate: nothing on the device serves `[platform]` yet
(above), so an update that could replace it would leave the machine unbootable.

## 9. Build budget: disk and CPU

The build root lives under `$BUILD_ROOT` (`~/.cache/omarchybook`) and the first full Phase 3
run died on it: the host filesystem filled to 100% and `omarchy-provision-user` aborted with
`mkdir: cannot create directory '/home/omarchy/.local': No space left on device`, after the
Omarchy set had already installed and `omarchy-apply-system` had reported
`Image build for aarch64-google: deferred 54 hardware steps to first boot`.

Measured on the 56GiB host, when the tree was full:

| Path | Size | Notes |
|---|---|---|
| `build-chroot/` | 13.5G | 8.5G of it is `build/`, makepkg's work directory from the Phase 1 kernel build |
| `work/rootfs-google-asurada/` | 9.1G | the installed desktop set |
| `pacman-cache/` | 2.4G | persistent and bind-mounted into the rootfs; worth keeping |
| `src/` | 1.1G | the patched `omarchy` checkout |
| `platform/` | 116M | the local package bundle |

So **`makepkg` must always be run with `--clean`**. Without it every kernel build leaves its
whole source tree (8.5G for one Linux tree) behind, owned by the chroot's `builder` (uid 1001, so
reclaiming it needs `sudo`), and nothing ever removes it because the recipes are only rebuilt when
their stamp changes. `scripts/build-omarchy.sh`, `scripts/build-package.sh` (the builder every
recipe goes through, the kernel included) and the `scripts/build-kernel.sh` wrapper all build with
`-fc`: the downloaded source tarballs are kept between runs via `SRCDEST`, and `PKGDEST` is emptied.
`scripts/build-rootfs.sh` refuses to start with less than 12GiB free and prints
the two directories to reclaim.

**`makepkg` does not set `MAKEFLAGS`, so every recipe built on a single core until this was
noticed.** The chroot's `/etc/makepkg.conf` ships `#MAKEFLAGS="-j2"` commented out and `makepkg`
never touches the variable at all (no reference in `/usr/bin/makepkg`), so `make` ran with no `-j`:
the Phase 1 kernel rebuild's top-level `make all` reported `MAKEFLAGS=rR` and the whole build sat on
one of 8 cores at ~25-36 objects/min — measured, with load 2.2, CPU 20% busy, disk 0% busy and PSI
stalls `avg10=0.00`, i.e. neither I/O-bound nor memory-bound, just serial. `lib.sh` now derives
`JOBS` (cores, capped by GiB of RAM: one kernel compile job costs a few hundred MiB, so 3.8GiB of
host buys 4) and exports `MAKEFLAGS=-j$JOBS`; the builders re-export it *inside* the chroot, because
`su` resets the environment and would drop it.

**A recipe's work tree survives an interrupted build, and only then.** `makepkg -c` removes
`$srcdir` after a successful build (that is the 8.5G leak above, still handled), but nothing removes
it when the build dies, so `$BUILD_CHROOT/pkg-build/<recipe>/recipe/src` is still there: the
builders therefore pass `--noextract` once that tree exists and the kernel recipe applies its
patches idempotently (`patch -R --dry-run` first, else "Reversed (or previously applied) patch
detected!" aborts `prepare()`). So killing a kernel build and re-running it resumes from the objects
it already compiled; a recipe whose *patch text* changed over such a tree is a conflict to resolve
by hand (`rm -rf` that `src/`), not something to paper over.

**Verifying anything inside a built rootfs needs the same mounts the build uses.** A bare
`chroot "$ROOTFS"` fails in confusing ways: `omarchy-hw-platform` — and anything else using bash
process substitution — dies with `/dev/fd/63: No such file or directory` unless `/dev` and `/proc`
are mounted, and `pacman -U` refuses with `could not open file: /etc/mtab` / `could not determine
filesystem mount points` unless `CheckSpace` is off (which is why the build comments it out). So
bind `/dev`, `/proc` and `/sys` first, and either disable `CheckSpace` or make the rootfs a mount
point. For that last part `mount --bind "$ROOTFS" "$ROOTFS"` does **not** work: a plain bind does
not carry the submounts, so it *hides* the `/dev`, `/proc` and `/sys` just mounted under it and the
chroot looks emptier than before — use `--rbind`. Always unmount afterwards: `build-rootfs.sh`
refuses to run while anything is still mounted under the rootfs, on purpose.

One build printed `libfakeroot internal error: payload not recognized!` from makepkg's
`tidy_install`. It did not reproduce on a rebuild, the package was well-formed (`pacman -U`
installed it, every entry `root/root`) and no other recipe has shown it, so treat it as fakeroot
noise unless it coincides with a broken package.

**A republished package keeps its version, so the pacman cache has to be refreshed.**
`build-rootfs.sh` copies the bundle into the image's `/packages` *and* into `$PACMAN_CACHE` because
pacman reuses a cached file that merely has the right name. The stamps are content-based: changing a
recipe or the vendored patch republishes, say, `omarchy-dev` under the same
`4.0.0.r7026.g51bfd1d-1`, and a stale cache entry then fails the repository checksum and aborts the
transaction — which is what happened once, at the very end of a twenty-minute build, after the patch
edit above. The same tension one level up is *not* solved here: a machine whose database already
holds that version will not upgrade to the republished bytes. A version-bump policy per patch
revision (or publishing the bundle as a real repository) belongs to the release/upgrade work of
Phase 6, together with the image carrying no `[platform]` repository at all.

## 10. The `[platform]` bundle: what it carries, and its signing (Phase 1)

**What is in it.** `linux-omarchy-book` + `-headers` (`scripts/build-kernel.sh`, from
`kernels/mediatek-mt81/`), `omarchy-dev` + `omarchy-settings-dev` (`scripts/build-omarchy.sh`, from
the pinned checkout) and `depthcharge-tools` (`scripts/build-package.sh`, from the vendored AUR
recipe, §7). `build-rootfs.sh` signs everything in it, indexes it with `repo-add`, installs the
device set from it, and asserts that it carries `$KERNEL_PACKAGE`.

**Signing is a build/release key of our own, kept outside the repository.** `lib.sh`'s
`ensure_platform_key` creates it on first use in `$BUILD_ROOT/keys/gnupg` (mode 700, root-owned, no
passphrase, `ed25519`, sign only) and exports the public half to `$BUILD_ROOT/keys/platform.pub`;
`sign_platform_packages` writes a binary detached signature next to each package (verified: `Good
signature`, and a second pass is a no-op). `keys/README.md` documents it.

**How the image trusts it, and why the database is not signed.** `build-rootfs.sh` imports
`platform.pub` into the image's keyring and `pacman-key --lsign-key`s it, so `[platform]` needs no
`SigLevel` override at all: the global `SigLevel = Required DatabaseOptional` applies and pacman
*requires* the package signatures — which replaces the `Optional TrustAll` a build-time bundle would
otherwise need. The private key never enters the rootfs, so `repo-add` signs nothing: it only copies
each `.sig` into the database as `%PGPSIG%`. Hence the `.sig` files must sit next to their packages
and must **not** be handed to `repo-add` as arguments — the old `/packages/*.pkg.tar.*` glob would
have, as soon as signatures existed.

**The kpart pipeline works end to end (this is Phase 1's acceptance).** `boot/make-kpart.sh` builds
the signed FIT from the built rootfs (`depthchargectl build --root none --board mt8192`, lzma, the
vendored devkeys) and `futility show` reports it:

```
Body verification succeeded.
Config:
kern_guid=%U quiet loglevel=2 root=UUID=… rootwait rw
```

Three things that surfaced there. `kern_guid=%U` **is** prepended by `mkdepthcharge` (the `Config:`
line carries it although `make-kpart.sh` deliberately does not add it), and `root=` is not in the
kpart: as in the Debian original, the callers pass it as the third argument (`root=UUID=… rootwait
rw`) — `install-kpart.sh` and `make-image.sh`, both of which run as root. That detail matters
because **mkinitcpio 42 creates the initramfs images 0600 on purpose** (`umask 077`: "create
initramfs images and unified kernel images as 600" — they may carry secrets), so an unprivileged
kpart build cannot read them; `make-kpart.sh` re-execs through `sudo` in that case instead of dying
inside depthchargectl. The mode is left as Arch sets it: the very same initramfs is world-readable
inside the kernel partition anyway. And two mkinitcpio messages are expected noise in this build,
not failures: `ERROR: failed to detect root filesystem` (the `autodetect` hook looks for a `root=`
that only the kpart's cmdline has, later) and `WARNING: architecture 'aarch64' not supported,
skipping hook` (the `microcode` hook; there is no aarch64 microcode to load).

## 11. The platform implementation: what `aarch64-google` must provide (Phase 4)

Omarchy keeps the *platform independent* part upstream and moves everything hardware-specific into a
platform package. `omarchy-mac-pkgs` is the model (a separate repository upstream); ours lives in
this repository and is published into `[platform]` like the kernel. Reading the two repositories
together (the vendored patch and the mac packages) gives the contract below.

**Registration.** The vendored patch already does it: `bin/omarchy-hw-aarch64-google` is the
predicate, `omarchy-hw-platform` maps the manifest's `google` and the `google,` device-tree prefix
to `aarch64-google`, and `bin/omarchy-lifecycle-dispatch` registers

| operation | implementation dir | package |
|---|---|---|
| `setup-system`, `setup-user`, `post-install`, `pre-remove` | `/usr/lib/omarchy/google` | `omarchy-google` |
| `setup-boot`, `update-verify` (**required**) | `/usr/lib/omarchy/google-boot` | `omarchy-google-boot` |

with `groups=('omarchy-platform-google')` and `provides=('omarchy-platform')` on the first one.
**A gap in the patch, copied from Apple's asymmetry**: `install/omarchy-aarch64-google.packages`
lists the *dependencies* (`keyd`, `alsa-ucm-conf`, `alsa-utils`, `pipewire-alsa`, `vboot-utils`,
`depthcharge-tools`, `linux-firmware-mediatek`, `linux-firmware-realtek`) but **not** the two
platform packages — Apple's list names `omarchy-mac` and `omarchy-mac-boot`. Without adding them,
nothing pulls the platform packages in and `setup-boot`/`update-verify` answer exit 3 forever.

**The leaf contract.** The dispatcher only execs an entrypoint that is a regular executable file
(never a symlink anywhere on the path to `/`), root-owned, with `(mode & 022) == 0` — so
`#!/bin/bash -p` and `install -Dm755`, which is what the mac `install` script does for every file in
`entrypoints/`. A leaf: rejects bad arguments with `exit 2`; re-checks the platform and **exits 0**
silently when it is not `aarch64-google`; is idempotent through negative-guard **marker files**
(never blind writes), e.g. a marker under `/var/lib/omarchy-google/` guarded by `[[ ! -f $marker ]]`;
preserves an administrator's override (an `/etc` override or a mask means "leave it"); and lets
failures propagate (`set -e`).

**Platform data is flat**: `/usr/share/omarchy-platform/{displays.conf,key-names,audio.json,
display-cutouts.json,keyrings}`, owned by the platform package. There is no per-platform
subdirectory — the plan said `/usr/share/omarchy-platform/google/` and that was wrong (§6 fixed).
Every reader tolerates a missing file, so a platform ships only what applies:

| file | format | read by |
|---|---|---|
| `displays.conf` | `backlight-skip <glob>`, `backlight-prefer <name>`, `ddc-require-connector-ddc` | `bin/omarchy-hw-display`, `bin/omarchy-brightness-display` |
| `key-names` | `<keysym> <name>`, both `^[A-Za-z0-9_]+$` | `bin/omarchy-menu-keybindings` |
| `audio.json` | `{"hidden":[<regex>…],"replaced":[{"node":…,"by":…}]}` | `shell/Commons/AudioNodes.qml` |

A Chromebook panel has no notch, so `display-cutouts.json` and `keyrings` (repository keyrings a
platform adds) do not apply and are left out.

**Hardware drop-ins the mac package uses and we need**: vendor directories
(`/usr/lib/udev/rules.d/` for the brightnessctl rule, `/usr/lib/systemd/…` for units and presets,
`/usr/lib/modprobe.d/`, `/usr/lib/tmpfiles.d/`, `/usr/lib/NetworkManager/`), which need no enable
step because systemd/udev/NetworkManager read the vendor path directly.

**Verified in a built rootfs (Phase 4).** The reader takes the flat path literally —
`key_names_file=/usr/share/omarchy-platform/key-names` in `bin/omarchy-menu-keybindings` — so the
platform package installs there and not under a per-platform directory. With `omarchy-google`
installed in a built image, `omarchy-lifecycle-dispatch setup-system image-first-boot` exits 0,
enables `keyd` (symlink in `/etc/systemd/system/multi-user.target.wants/`), adds the `wheel` members
to `video` and writes its markers into `/var/lib/omarchy-google/`; a second run writes nothing.
`systemctl enable` works offline, in an image build, while `start` is guarded by
`/run/systemd/system`. The leaf uses "members of `wheel`" as its notion of the desktop user because
a Chrome OS image has no better marker; on an image built from ALARM's tarball that is both the
provisioned user and ALARM's own `alarm` account — which is why that account is now a hygiene item
in plan Phase 6.

## 12. The boot chain, ported and shipped (Phase 5)

**What ships, and where the files live.** `platform/omarchy-google-boot/` carries the two operations
the dispatcher requires of this platform (`setup-boot`, `update-verify`), the command they share
(`/usr/bin/omarchy-google-boot`, with a third subcommand `kpart-rewrite` for the ALPM hook), the
ALPM hook itself, and the boot chain: `lib-cgpt.sh`, `make-kpart.sh` and `install-kpart.sh` under
`/usr/lib/omarchy/google-boot/`, with the devkeys and the `deviceinfo`/`kernel-cmdline.conf` the
device-side configuration derives from. None of those is a copy kept in the package: the recipe
lists them in `extra.list`, and `scripts/build-package.sh` stages the paths it names under
`recipe/extra/`, counting them towards the recipe's hash — so editing `boot/` or the device files
rebuilds the package, and there is exactly one copy of each script in the tree.

The ported scripts source a lib *beside themselves*. In this repository that is `boot/lib.sh`, a
three-line wrapper around `scripts/lib.sh` (which knows about checkouts, build trees and rootfs
directories); on the device it is the package's own `lib.sh`, which derives the same facts from the
shipped `deviceinfo` and from `uname -r`. The package's tests run both and compare the values, which
is the anti-drift check; inside a build chroot, where the repository is not visible, the hash over
`extra.list` is what keeps them in step.

**The chroot guard never fired, and the Debian original has the same bug.** Every script in the chain
resolves the kernel partition from `kern_guid` in `/proc/cmdline`, and inside a chroot that file
describes the *host* — so a chroot could rewrite the host's kernel partition. The ported guard tried
to catch that with

```sh
[ "$(stat -c %d:%i /)" = "$(stat -c %d:%i /proc/1/root)" ]
```

which cannot work: `stat` does not dereference the last component, so `/proc/1/root` reports the
*procfs symlink* (device `0:28`) and never equals `/`. Measured in the built rootfs, the guard's two
sides are `45827:1227503` and `28:685210`; with `-L` they are `45827:1227503` and `45827:2`, which is
the answer the check was written for. Note what "the answer" is: *equal* means this root is PID 1's
root, i.e. a real system, so the guard has to refuse when they **differ** — the ported code refused
when they were equal, i.e. always on a real system had `-L` been there.

The fix lives in one place, `lib-cgpt.sh`: `in_chroot()` answers the question and
`require_real_root()` refuses, and `install-kpart.sh` and the lifecycle command call it. Tried both
ways: on the build host `in_chroot` is false and `require_real_root` returns; inside the built rootfs
`in_chroot` is true and it dies with `ERROR: running in a chroot: /proc/cmdline describes the host,
not this system`.

**The hook must not be able to break a transaction.** `kpart-rewrite` is the one caller that *skips*
rather than refuses: it fires inside pacman transactions, and the image build is one of them, so a
failure would abort the build. It reports `WARN: not rewriting the kernel partition: running in a
chroot, not the booted system` and exits 0. Verified end to end by reinstalling the kernel package
inside the built rootfs: pacman ran mkinitcpio's hook, then ours (5/5 — the numbering is what puts
it after), the guard skipped the write, and pacman exited 0. `setup-boot` and `update-verify` are
the opposite: they only make sense on a booted system, so both refuse in a chroot rather than
report about the host.

**The command's own platform check reported a verdict it had not made.** `omarchy-google-boot`
refuses to act on a machine that is not `aarch64-google`. The first version called
`omarchy-hw-aarch64-google` bare and treated *any* failure as "not Google", so a build log said `not
an aarch64-google machine` about an aarch64-google image, with two unrelated causes it could not tell
apart: a hook has no `PATH` worth trusting (detectors are called by absolute path — they resolve their
own siblings and refuse an unprivileged Bash startup, and `bin/omarchy-lifecycle-dispatch` calls them
exactly that way), and an image build installs this package *before* the runtime that ships the
detectors. The command now resolves the detector beside itself, calls it with the dispatcher's fixed
`PATH` when root, and separates the answers: `kpart-rewrite` checks the chroot first — so a build never
asks the detector at all and reports the skip — and only then warns "not an aarch64-google machine, or
its detector is not installed yet" if the check genuinely cannot be made, while `setup-boot` and
`update-verify`, which the dispatcher only calls on a booted system, refuse outright. The package's
tests assert all three parts.

**The image manifest now goes in before the package lists.** `omarchy-hw-platform` answers from
`/var/lib/omarchy/image/target` inside a chroot and *deliberately* never reads the build host's device
tree — an image is built away from the machine it will run on — and `build-rootfs.sh` was writing that
file *after* the lists, i.e. after everything that could have asked. It is pinned before them now,
which is where the comment above it always said it belonged ("so package setup describes the target
rather than the builder"). No package changes: the file is the builder's, not a package's.

**Two `[Trigger]` sections, not one with two `Type` lines.** A first version used one section with
`Type = Package` and `Type = Path`; pacman warned `overwriting previous definition of Type` at
install time, because its INI parser keeps the last value of a repeated key — the hook would have
silently dropped the package condition. `apply`-style hooks in the image (mkinitcpio's own
`90-mkinitcpio-install.hook`) express several conditions as several `[Trigger]` sections, which is
what the shipped hook does now. The package's tests count `Type` lines per section, so the warning
cannot come back unnoticed.

**`depthcharge-tools` does not run on python 3.14, and the AUR recipe declares neither that nor the
programs it shells out to.** Found by running the boot chain the device will run — inside a *built*
rootfs, not the build chroot — and it took three fixes (all recorded in the recipe's
`PROVENANCE.md`):

1. `depthcharge_tools/utils/argparse.py` builds positionals with `nargs=0`, which 3.14's argparse
   rejects (`ValueError: nargs for positionals must be != 0`). The parser is class-level and built at
   import time, so even `depthchargectl --version` died.
2. `depthcharge_tools/__init__.py` imported `pkg_resources`. The first attempt was to add
   `python-setuptools` as a runtime dependency, which is the reflex and is *wrong*: setuptools
   **84.0.0** (ALARM's, and the version in the image) ships no `pkg_resources` at all, so the dep
   changed nothing and only dragged in the `python-jaraco*` chain.
3. With both fixed, the build dies on missing *programs* — first `[Errno 2] No such file or directory:
   'fdtget'`, then, once `dtc` is declared, the same on `mkimage`. `depends=('python')` names none of
   the programs upstream's README lists as dependencies: `fdtget`/`fdtput` (`dtc`),
   `futility`/`vbutil_kernel`/`cgpt` (`vboot-utils`), `mkimage` (`uboot-tools`). The compression tools
   are already in the image and `lzma` (xz) is the one this board's FIT uses; `crossystem` is not
   packaged on Arch at all and is only for its own subcommands.

The release is from 2021, and upstream master (`1c123c8`) already carries fixes 1 and 2 as ordinary
commits. They are cherry-picked rather than built from master, because the boot chain in
`debian-aarch64` — the one verified on this hardware — was built with 0.6.2's semantics, and the ~40
commits since change FIT construction (`Remove default configuration from FIT image`, verity, TPM).
`depends` now names `python-packaging`, `dtc`, `vboot-utils` and `uboot-tools`; `python-setuptools`
stays a makedepend. `pkgrel` stays `1`, as everywhere in `[platform]`: the bundle is content-addressed
and `build-rootfs.sh` refreshes the cache from it.

**Verified end to end inside a rebuilt rootfs.** After `scripts/build-rootfs.sh` — which now pulls
`dtc`, `uboot-tools`, `python-packaging` and `vboot-utils` in through the recipe's dependencies, with
no manual step — the *device's* copy of the chain builds a FIT from the image it is installed in:
`/usr/lib/omarchy/google-boot/make-kpart.sh / /tmp/kpart.img "root=UUID=… rootwait rw"` exits 0 and
writes 30 MiB, `futility show` reports `Header version: 2.2`, `Body verification succeeded` and the
flags `!DEV DEV !REC`, and `mt8192-asurada-hayato-r1.dtb` is the first DTB in the image. That is
phase 1's acceptance re-run through the files the package ships, on the python the device runs,
instead of on the build host.

**What only a boot can settle.** Everything above is verified in a chroot. Writing p1, the hook on a
real kernel update, `setup-boot` on the first boot of a freshly written card, and the Unicode/keyd
side of the platform layer all need the machine — i.e. Phase 7.

## Still open (need a chroot or hardware — not answerable read-only)

1. **Resolved**: the built `depthcharge-tools` installs no kernel/initramfs hooks on Arch (verified
   from the package file list), so they need not be disabled as on Debian.
2. **Resolved**: the vboot developer keys are vendored into `boot/devkeys/` (from `vboot_reference`
   `10343b821`, recorded in `boot/devkeys/README.md`), and a kpart built with them verifies —
   `futility show` reports `Body verification succeeded` (plan Phase 1, §10 above).
3. **Resolved**: `pacman -U` and `mkinitcpio` behave as expected inside the Phase 1/2 chroot — the
   package installs over ALARM's `linux-aarch64`, which ours conflicts with, and `mkinitcpio -P`
   builds both images from the preset (§9, plan Phase 1).
4. **Open**: whether LUKS is wanted later (plan §8) and whether the SD card must self-install to
   eMMC (assumed yes). A maintainer decision rather than a recon question; Phase 6 has the tooling.
5. **Open**: the exact versions the first working boot ends up holding, which is the whole pinning
   policy of plan §3. §5 records what the repositories offer, not what the card ends up holding —
   only a boot on hardware closes this, in Phase 7.