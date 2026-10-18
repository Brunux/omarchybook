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
`setup-system`/`setup-user`/`post-install`/`pre-remove`) — the model for `book-boot` / `book`.

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
| `setup-system`, `setup-user`, `post-install`, `pre-remove` | `/usr/lib/omarchy/book` | `omarchy-book` |
| `setup-boot`, `update-verify` (**required**) | `/usr/lib/omarchy/book-boot` | `omarchy-book-boot` |

with `groups=('omarchy-platform-book')` and `provides=('omarchy-platform')` on the first one.
**A gap in the patch, copied from Apple's asymmetry, was found and closed**:
`install/omarchy-aarch64-google.packages` originally listed only the *dependencies* (`keyd`,
`alsa-ucm-conf`, `alsa-utils`, `pipewire-alsa`, `vboot-utils`, `depthcharge-tools`,
`linux-firmware-mediatek`, `linux-firmware-realtek`) and **not** the two platform packages — Apple's
list names `omarchy-mac` and `omarchy-mac-boot`. Without them, nothing pulls the platform packages in
and `setup-boot`/`update-verify` answer exit 3 forever. The patch now ends the list with
`omarchy-book` and `omarchy-book-boot`.

**The leaf contract.** The dispatcher only execs an entrypoint that is a regular executable file
(never a symlink anywhere on the path to `/`), root-owned, with `(mode & 022) == 0` — so
`#!/bin/bash -p` and `install -Dm755`, which is what the mac `install` script does for every file in
`entrypoints/`. A leaf: rejects bad arguments with `exit 2`; re-checks the platform and **exits 0**
silently when it is not `aarch64-google`; is idempotent through negative-guard **marker files**
(never blind writes), e.g. a marker under `/var/lib/omarchy-book/` guarded by `[[ ! -f $marker ]]`;
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
platform package installs there and not under a per-platform directory. With `omarchy-book`
installed in a built image, `omarchy-lifecycle-dispatch setup-system image-first-boot` exits 0,
enables `keyd` (symlink in `/etc/systemd/system/multi-user.target.wants/`), adds the `wheel` members
to `video` and writes its markers into `/var/lib/omarchy-book/`; a second run writes nothing.
`systemctl enable` works offline, in an image build, while `start` is guarded by
`/run/systemd/system`. The leaf uses "members of `wheel`" as its notion of the desktop user because
a Chrome OS image has no better marker; on an image built from ALARM's tarball that is both the
provisioned user and ALARM's own `alarm` account — which is why that account is now a hygiene item
in plan Phase 6.

## 12. The boot chain, ported and shipped (Phase 5)

**What ships, and where the files live.** `platform/omarchy-book-boot/` carries the two operations
the dispatcher requires of this platform (`setup-boot`, `update-verify`), the command they share
(`/usr/bin/omarchy-book-boot`, with a third subcommand `kpart-rewrite` for the ALPM hook), the
ALPM hook itself, and the boot chain: `lib-cgpt.sh`, `make-kpart.sh` and `install-kpart.sh` under
`/usr/lib/omarchy/book-boot/`, with the devkeys and the `deviceinfo`/`kernel-cmdline.conf` the
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

**The command's own platform check reported a verdict it had not made.** `omarchy-book-boot`
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
`/usr/lib/omarchy/book-boot/make-kpart.sh / /tmp/kpart.img "root=UUID=… rootwait rw"` exits 0 and
writes 30 MiB, `futility show` reports `Header version: 2.2`, `Body verification succeeded` and the
flags `!DEV DEV !REC`, and `mt8192-asurada-hayato-r1.dtb` is the first DTB in the image. That is
phase 1's acceptance re-run through the files the package ships, on the python the device runs,
instead of on the build host.

**The installer reproduces pmbootstrap's path, which is the one proven on this machine.** The
sibling ported that path line by line (`partition_cgpt()`, `sanity_check_boot_size()`,
`mount_disk()`, `format_partition_with_filesystem()`, `create_fstab()` in `pmb/install/`), and this
port carries the same code in `boot/lib-cgpt.sh`, with every deviation called out at the line that
makes it. What changed here, and what forced each change:

- **The root partition ends 33 sectors before the end of the device, not 2048.** Those 33 sectors are
  the 32-sector secondary GPT plus its header, and `partition_cgpt()` sizes the partition around
  them. Measured on a 2048 MiB loop: `p3 1318912+2875359`, `Sec GPT table` at sector 4194271 and the
  header at 4194303 — and the same arithmetic in a 4096 MiB image built by `make-image.sh`
  (`p3 1318912+7069663`). `- 2048` only wasted a MiB; what it did not do was leave the backup table
  where the proven layout puts it.
- **A mounted partition is refused instead of unmounted silently**, as `mount_disk()` does
  ("is mounted! Will not attempt to format this!"). The test for it cannot be `mountpoint -q`: that
  asks whether the *path* is a mount point, which a device node never is. Measured with `p2` mounted,
  `mountpoint -q /dev/loop0p2` exits non-zero while `findmnt -rn -S /dev/loop0p2` names the
  mountpoint — so the old loop never unmounted anything either, and went on to `wipefs` and `mkfs`
  over whatever was mounted. The refusal fires with `ERROR: /dev/loop0p2 is mounted; unmount it first
  (udisksctl unmount -b /dev/loop0p2) and run again`; both the loop-device rehearsal and an image
  build leave the function with nothing to unmount, because neither mounts anything before calling
  it. `wipefs` is gone as well: `disk_layout_create()` zeroes both GPT areas itself and `mkfs -F`
  overwrites the signatures inside the partitions.
- **`mkfs` gets `-q`, and `partprobe` runs right after the `cgpt add`s**, as
  `format_partition_with_filesystem()` and `install_system_image()` do.
- **`/etc/fstab` gets pmbootstrap's options**: `defaults` for the root and `nodev,nosuid,noexec` for
  `/boot`, which is also how the running Nura mounts its `/boot`. Two lines differ from the sibling,
  both deliberately. The root keeps `errors=remount-ro`: pmbootstrap does not set it, and ext4's own
  default is `Errors behavior: Continue` (measured with `tune2fs -l` on a fresh `mkfs.ext4`), so
  without it a bad filesystem corrupts in place instead of remounting read-only — the maintainer's
  call. And the pass column stays `0 1`/`0 2`: pmbootstrap writes `0 0` because its init fsck's for
  itself, while this image has systemd-fsck to order the two. `noatime` was dropped as the sibling
  did: the kernel mounts `defaults` as `relatime`, which is what it was there for.
- **A boot partition below 512 MiB is refused**, as `sanity_check_boot_size()` does. Measured:
  `BOOT_SIZE_MIB=256` dies before a single sector is written.
- **The kpart's command line is joined with an explicit separator.** `KERNEL_CMDLINE` comes from
  `tr '\n' ' '` over `kernel-cmdline.conf`, which produces a separator only when that file ends with
  a newline. Measured with a file that does not end with one: `quiet loglevel=2root=UUID=…`, a single
  argument depthcharge would hand the kernel as-is; `boot/make-kpart.sh` builds the space itself now.
  `devices/google-asurada/kernel-cmdline.conf` does end with a newline, so here it was latent — in the
  sibling it was live, which is how it was found.

**The same rehearsal found a bug this port had, and the sibling still has: resolving partitions by
position.** `disk_layout_parts()` took the 2nd, 3rd and 4th lines of `lsblk` — which lists a disk's
partitions in the order the kernel handed out their minors — and `disk_layout_create()`'s
`partx -d`/`-a` round, the one that makes the kernel re-read the table it was just given, reorders
them. Measured over 16 attaches of a 2048 MiB loop: 3 came back as `3 1 2` or `2 1 3`, with no line
missing, so the old code would have formatted `p2` as the root filesystem and written the kpart into
`p3`; that is exactly the state the failing rehearsal left behind (`p2` carrying `LABEL="pmOS_root"`
and `p3` unformatted). It is not the `partprobe` the parity pass added: in an A/B of 8 attaches each,
the order drifted once with it and twice without it. The function resolves by partition number
(`PARTN`, never position) and asserts the three `pmOS_*` labels now, so a wrong resolution fails
loudly instead of formatting or overwriting the wrong partition; 16 of 16 attaches resolve correctly,
including the two that came back ordered `3 1 2` and `2 1 3`. An image built by `make-image.sh` in
that state has `pmOS_boot` on p2 and `pmOS_root` on p3, each with its filesystem, and the kpart's
`root=UUID=` equal to p3's. The sibling's released v0.1.0 was built with the positional code, so
whatever layout its builds produced hung on that order — worth reporting there. The image this port
published is not affected: its kpart's `root=UUID=` was checked against p3 at release time, which
only matches if p3 really carries the root filesystem.

Both refusals, the geometry and the generated fstab were verified off-device, which is all of it that
can be: `make-image.sh` end to end against a fixture rootfs (the real kernel, initramfs and DTBs, ~35
MiB) reported `futility: dev-signed FIT, preamble 2.2, body verification succeeded`, the kpart's
`root=UUID=` equal to the image's p3, and the new fstab inside the image with the secondary GPT
intact.

**What only a boot can settle.** Everything above is verified in a chroot. Writing p1, the hook on a
real kernel update, `setup-boot` on the first boot of a freshly written card, and the Unicode/keyd
side of the platform layer all need the machine — i.e. Phase 7.

## 13. Image, release, install and backup (Phase 6)

**What was actually run.** Nothing in this phase needs hardware except the boot at the end of it, so
every script was rehearsed against a fixture rootfs (`$WORK_DIR/rehearsal/fakerootfs`: the real
kernel, initramfs and DTBs, ~35 MiB, plus deliberate decoys -- a Wi-Fi profile with a PSK,
`ssh_host_rsa_key`, a non-empty `machine-id`, `/home/brunux/.cache/omarchybook/work`, `/packages`,
`/var/log/pacman.log`, `/tmp/pulse-*`) and against loop devices: `write-sd.sh` on a 2 GiB card,
`make-image.sh` twice (fixed 2 GiB and the automatic size), `make-release.sh` end to end,
`backup-system.sh` on the host with heavy `BACKUP_EXCLUDES`, and `restore-system.sh` against a
synthetic backup on a 6291456-sector loop with `DEEP=yes`. Green results: the GPT with the three
ChromeOS entries and `priority=10 tries=5 successful=1` on p1, a 30 MiB FIT that `futility show`
accepts (`preamble 2.2`, `Body verification succeeded`), fstab UUIDs matching `blkid`, the decoys
gone from the published tree and *not* in the image's bytes, the released `.img.xz` verifying with
`xz -t`, `tar -d` agreeing with the restored filesystems, and all five refusals (different disk size,
a partition instead of a disk, not a block device, no `CONFIRM=yes`, a tampered `SHA256SUMS`).

**The build rootfs carries more than the port, and some of it is the maintainer's.** Measured in the
built rootfs before `lib-dist.sh` existed: `/var/cache/pacman/pkg` is the persistent download cache
bind-mounted in by `build-rootfs.sh` (2.4 GiB, recon §9), `/packages` holds the whole build-time
`[platform]` bundle (251 MiB) which the Omarchy post-install leaf made unreachable when it rewrote
`/etc/pacman.conf`, `/var/log/pacman.log` (80 KiB) and `/var/log/omarchy-install.log` (8 KiB)
transcribe the build, `/tmp` kept `pulse-PKdhtXMmr18n` and an omarchy lock file, and
`/home/brunux/.cache/omarchybook/work` existed three levels deep -- the Phase 5 verification ran
`make-kpart.sh` *inside* the image, where `$HOME` was the maintainer's, so `$WORK_DIR` was recreated
there. All of that is now excluded from the copy and asserted absent: excluding rather than deleting
is what keeps the bytes out of the image (the rule the Debian original measured), and a `/home/<name>`
with no account in `/etc/passwd` is a fatal finding, which is what caught the last one.

There are no Wi-Fi profiles in the built rootfs at all: `$WIFI_DIR` is defined and exported by
`scripts/lib.sh` but nothing imports it, unlike the Debian build. So the byte check
(`dist_assert_no_profile_bytes`) is currently vacuous -- it reports "No Wi-Fi profile in $ROOTFS or
$WIFI_DIR: nothing to look for". It is kept, and tested with a decoy (a profile planted in the
fixture is found and publication is refused), because a card built from a rootfs somebody has logged
into *will* have profiles, and because that is the check that caught the same leak on the Debian side.

**The build host's `du` and `cp` are BusyBox.** `du --apparent-size` and `du -B` do not exist there
(`du: unrecognized option: B`), and neither does `cp --sparse=always`. Nothing in the released
scripts may depend on GNU-only flags: `lib.sh` grew `du_mib()`/`file_mib()` (KiB, then divide),
`make-image.sh` computes its default size with the former and reports the image with `stat -c %s`.
`df -Pk` is fine as it is. The Arch target has coreutils, but these scripts run on the build host,
which is this one.

**The pipefail trap, again, in a check written for this phase.** `00-deps.sh` tested GNU tar's
options with

```sh
if ! tar --help 2>/dev/null | grep -q -- "$_o"; then
```

and reported `tar --xattrs` missing on a tar that has it. The reason is the one §12 records for
`grep -q` under `set -o pipefail`: `grep` exits on the match, `tar` gets SIGPIPE, the pipeline
returns 141 and `!` turns that into "the option is missing". It only fired for `--xattrs` because
that appears at line 167 of 324 lines of help, while `--acls` appears after tar has finished writing
and no signal is ever sent. Fixed by capturing the help into a variable first. `lsblk -no PKNAME ... |
head -1` in `backup-system.sh` and `restore-system.sh` carries the same hazard (a disk with nested
children lists more than one line) and now ends in `|| true`.

**`repo-add`'s database lives in the image, not in the bundle.** `$BUILD_ROOT/platform` holds the
packages and their `.sig` and nothing else: `repo-add` runs inside the build rootfs, against
`/packages`, so `platform.db.tar.gz` exists only there. `make-release.sh` therefore assembles the
release's `platform/` from the *rootfs*, not from `$PLATFORM_REPO` -- which also means the database
matches exactly the packages that image was built with, and that the database is unsigned (the
released image's global `SigLevel = Required DatabaseOptional` accepts that, and every package
carries its own signature).

**`backup-system.sh` refuses a chroot, unlike the Debian original.** Nothing in it writes to the
machine, so this is not about safety but about the artifact being right: from a chroot the tars are
the chroot's root filesystem while the kernel partition and the partition table recorded beside them
belong to the host -- a backup whose p1 does not match its rootfs, which is worse than no backup
because it looks complete. `require_real_root()` is the same guard the rest of the chain uses
(§12).

**A chroot's `/dev` is a build input, not furniture.** The Phase 7 kernel rebuild compiled for an
hour and then died in makepkg's packaging phase with `/dev/null: Permission denied` and `ERROR:
Failed to create the directory $BUILDDIR`: `BUILD_CHROOT/dev/null` had been replaced by a plain
0644 file, so the build's own user could not write to it -- while `build()` itself got away with it,
because the host's `/dev` is bound over that directory for the run. `lib.sh`'s `device_nodes()`
recreates the standard nodes where one is missing or is not a device, called by `build-package.sh`
and `build-rootfs.sh` *before* their bind mounts (never through them: `mknod` under the bind would
change the host's own devices). The lesson is about *when* a phase fails: a broken `/dev/null` costs
nothing until the part of the build that runs as the unprivileged builder.

**The pinned upstream tree can be reused offline.** `git fetch --depth 1 origin $OMARCHY_COMMIT` is
how the build gets the exact tree the recipes are written against, and this host has had stretches
with no route to github.com while nodejs.org answered normally. The fetch is now required only when
the object is missing: if it fails and `cat-file -e $OMARCHY_COMMIT^{commit}` succeeds, the build
warns and checks out the copy already in `src/`. The commit is part of the recipe (`lib.sh`), not a
moving target, so reusing exactly it is what the pinning asked for rather than a shortcut around it.

**The real release was run, and the disk budget it needs is measured now.** v0.1.0 was built from the
real 9.7 GiB rootfs, and the estimate above was optimistic. What the build actually holds at once:
the rootfs 9.7 GiB, the image 11.8 GiB apparent (9.6 GiB allocated), the staging copy `lib-dist.sh`
sanitizes 9.5 GiB, the `.xz` 2.5 GiB and the rootfs tarball 3.0 GiB -- three copies of the system
before the compressed pair exists, about 25 GiB of working disk rather than the 13 GiB the host had.
The first attempt died exactly there, `zstd: error 70 : Write error : cannot write block` at 2.2 GB
into the tarball, and a full disk also stops the tooling that records a failure from writing why, so
space had to be freed before the reason could be read. `$BUILD_CHROOT` (4.9 GiB) and the pacman cache
(2.8 GiB, recon §9) are the reclaim: both are rebuilt by the next rootfs build.

**Two of the assets are larger than any release host takes.** GitHub refuses a file of 2 GiB or more,
and both the image and the rootfs tarball are over it -- the tarball was already past 2.2 GB when it
ran out of disk. The release therefore publishes them in parts, `<name>.part-aa`, `.part-ab`, cut at
1800 MiB with `split -b 1887436800` (BusyBox `split` takes bytes: `-b 2M` is "invalid number").
`SHA256SUMS` hashes the whole file, so `cat <name>.part-* > <name> && sha256sum -c SHA256SUMS` is
what proves a part is neither missing nor corrupt. The raw `.img` is not published and is no longer
listed in `SHA256SUMS`: hashing a file nobody can download made the check fail for everyone who did.

**A tagged build recorded `tag: none`.** `RELEASE-INFO.txt` read the commit at the start of the build
and the tag at the end, so a commit made during the 40-minute build moved HEAD out from under the
`git describe --exact-match`. Both are now read together, pinned to the same commit.

**Still not run on this host.** `sgdisk` is absent (gptfdisk), so `backup-system.sh` warns and records
the raw GPT dumps only -- a restore onto a disk of the same size works with those, and the portable
`<host>-gpt.bin` (the way onto a different disk) needs the package installed.

**`install-emmc.sh` inherits the sibling's eMMC fix.** The sibling installed its running system onto
the eMMC and the machine did not boot it: the kernel partition and its payload were byte-identical to
the card's, and the firmware did load the kernel, so it read as firmware or kernel -- what was on
screen said what it was: `run-init: opening console: No such file or directory` (six times),
`Target filesystem doesn't have requested /sbin/init`, `No init found. Try passing init= bootarg.`
The excludes passed to rsync are about *contents*, but rsync also drops the excluded *directories*,
and `/dev`, `/proc`, `/sys`, `/run`, `/mnt` and `/media` are the mount points the initramfs's
run-init moves its own devtmpfs into before handing over to systemd, so the copy came out without
them. `install-emmc.sh` now recreates them after the copy (`install -d` with the running system's
modes) and refuses to write p1 unless `/dev` exists and `/sbin/init` resolves: a rootfs that cannot
be entered must never reach the kernel partition, because the next reboot dies without a console to
say why. The same fix makes the copy its own machine -- `: >` on `/etc/machine-id` and removal of
`/etc/ssh/ssh_host_*`, exactly what `lib-dist.sh` does for a published artifact, with systemd
generating a fresh id and `sshdgenkeys.service` the host keys at the first boot -- forwards `CONFIRM`
through the `sudo -n` re-exec (which starts from a clean environment and had been dropping it, so the
documented `CONFIRM=yes scripts/install-emmc.sh` could never pass the guard), and names the firmware
menu (`internal disk` is the eMMC, `external disk` the microSD) instead of Ctrl+U in its closing
message. The companion fix carries the same `CONFIRM` (and `DEVICE`) through the `sudo -n` re-exec of
`boot/install-kpart.sh`, whose guard asks for `CONFIRM=yes` in its own error message and had been
unreachable the same way. Ported from the sibling, where the eMMC install was verified on hardware
and reaches the desktop; on this port the eMMC boot is Phase 7's.

## 14. The health report, and what it had to learn about the port (Phase 7)

`scripts/check-system.sh` is the Phase 6 checker from `debian-aarch64` ported to Arch and re-derived
from this port's own decisions, so the checks describe the machine this repository actually builds.
The measurements behind them, all from the built rootfs or from the checkout:

- **The session is not the sibling's.** SDDM with `DisplayServer=wayland`, theme `omarchy`, and
  `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`; the session entries are
  `hyprland-uwsm.desktop` and `hyprland.desktop`; the shell is Quickshell and the lock is Omarchy's
  own (`omarchy-system-sleep-monitor`, the user unit `omarchy-sleep-lock.service`). There is no
  swaybar, no waybar, no mako, no hyprlock and no greetd to look for — the sibling's checks for those
  tools would have been red on a working system.
- **Two accounts, one of them on purpose.** The build makes `omarchy` (uid 1001) and provisions its
  config; ALARM's `alarm` (uid 1000) stays with a password (plan §3, decision 8). The report names
  every account that has one instead of assuming a single desktop user, which is the plan's own
  audit requirement against the device rather than against the checklist.
- **The platform answer has two sources.** `omarchy-hw-platform` reads `google,<board>` from the
  device tree on a booted machine and `/var/lib/omarchy/image/target` while an image is still
  un-booted; the first boot retires that manifest to `target.booted` and works through
  `deferred-steps`, `pacman-keyring`, `initramfs-inputs` and `boot-rebuild`. Each is a check, because
  a first boot that half-finished leaves no other trace.
- **Fonts, from Omarchy's own configuration.** It asks for `JetBrainsMono Nerd Font` (15 mentions
  across the Hyprland config and the shell), `Noto Color Emoji` and the CJK Noto families; the
  `woff2-font-awesome` package in the image is for web apps, not for the bar.
- **Audio is the MT6359 + RT1015P + RT5682 combination**, whose UCM files are
  `/usr/share/alsa/ucm2/MediaTek/mt8192/mt6359-rt1015p-rt5682/`, and the desktop is driven through
  `pactl` (volume, sink switching, tuning) as well as `wpctl`.
- **The kernel's name is `-mt81`** (`CONFIG_LOCALVERSION`), so the package version (`7.2.7-2`) and
  `uname -r` (`7.2.7-mt81`) only agree in their numeric part: the report compares that part and the
  flavour separately, or a stale `/boot` would pass for an up-to-date kernel partition.
- **The FIT carries the root UUID it was built for.** `futility show` on a kpart ends with
  `Config: kern_guid=%U quiet loglevel=2 root=UUID=<the root it was built against>`, and this host's
  build work tree still holds one built against a rehearsal fixture (`db0ed901-…`). The report reads
  the FIT out of the partition `/proc/cmdline`'s `kern_guid` names and fails when its `root=UUID=`
  is not the running root's — the one check that catches a prebuilt kpart written onto a disk that
  was partitioned to different UUIDs.

**Fixed while porting it: `pipewire-pulse` was missing.** The image had `libpulse` (so `pactl`
exists) but no PulseAudio-protocol server, because upstream keeps `pipewire-pulse`,
`pipewire-jack`, `gst-plugin-pipewire` and `lsp-plugins-lv2` in `install/omarchy-other.packages` --
the ISO builder's list, which this port deliberately does not install (§8). `pactl` is not optional
for the desktop, though: `omarchy-audio-output-volume`, `-output-switch`, `-output-set-default`,
`omarchy-audio-sink-availability` and `omarchy-audio-tuning` all drive it, and the
`omarchy-capture-*` commands ask it for the monitor source, so without the server the volume keys,
the audio OSD and recording with sound fail on a PipeWire stack that otherwise looks complete. It is
now in `packages/omarchy.list`; the other three stay out on purpose (`pipewire-jack` and
`lsp-plugins-lv2` are for speaker tunings this device has none of, and `gst-plugin-pipewire` for
audio in GStreamer apps, neither of which is a boot-blocking gap).

**The rehearsal porting it needed.** Running the report inside the built rootfs (repository bind-mounted
read-only at `/mnt/repo`, `/dev`, `/proc` and `/sys` bound so redirects and `dmesg`-less reads work)
caught three things a straight port would have carried over wrong: `pacman -Qq linux-omarchy` answers
with `linux-omarchy-book`, because pacman matches `-Q` targets as patterns, so the kernel-absence
check and the declared-package check now compare exact names against the local package list;
`/etc/os-release` is Omarchy's own, not ALARM's (`ID=omarchy`, `ID_LIKE=arch`), so the architecture
has to be read from `ID_LIKE`; and `systemctl is-active sddm` answers *active* inside a chroot whose
`/proc` is the host's even with no `/run/systemd` — the host runs sddm too — so every unit check has
to sit inside the live gate. With those fixed the chroot run is 39 ok, 6 warn, 0 FAIL, 13 skip, and
the three warnings worth reading are the un-retired image manifest (`target`, `deferred-steps`,
`pacman-keyring`), which is exactly what an un-booted image should report, plus the password audit.
The declared-package check passing is the one that validates the composition and the aarch64 filter
against the real rootfs.

**What the report cannot check off hardware.** Everything live: dmesg, `/sys`, `/proc/cmdline`,
`/proc/asound`, the session and PipeWire. `check-system.sh` now says so instead of reading the wrong
machine -- it detects a chroot the way the boot chain does (`boot/lib-cgpt.sh`) and stands its live
sections down. That is also why this host cannot test them: the shell this repository is developed
from runs under a namespace whose PID 1 is `init` and where `/run/systemd/system` does not exist, so
its readings are the sandbox's, and the script skips them exactly as it would in a chroot. The live
half is exercised for the first time by the first booted card, which is Phase 7's acceptance.

**What the first booted card taught (2026-10-17).** The card booted and produced
`reports/2026-10-17-first-boot.txt` (95 ok, 3 warn, 2 FAIL, 2 skip, run from tty1 before any desktop
existed) with `reports/2026-10-17-diagnostics.txt` as its journal-level context
(`scripts/collect-diagnostics.sh`). Everything the report says about this hardware is right --
`google,hayato-rev1`, panfrost `mali-g57` on `card1-eDP-1`, the `664 video` backlight, the MT6359
audio profile at `HiFi` with both sinks and a monitor source (which is what proves the
`pipewire-pulse` fix), `DFS-FCC`, Bluetooth on `asuara`, s2idle, 41 declared packages -- and the two
FAILs and three warns resolved into two porting bugs, one kernel gap, and readings of a boot that is
not the one the report was run on:

- **ufw cannot start: its rules use netfilter matches this kernel did not build.** `ufw.service`
  exits 1 with `line 24: RULE_APPEND failed (No such file or directory): rule in chain
  ufw6-before-input` and `Problem running '/etc/ufw/before6.rules'`, preceded by `Extension limit
  revision 0 not supported, missing kernel module?` and the same for `rt`. `/etc/ufw/before6.rules`
  line 24 *is* `-A ufw6-before-input -m rt --rt-type 0 -j DROP`; the `hl` matches are `ip6t_hl`, and
  `before.rules` line 63 logs with `-m limit`. With `XT_MATCH_LIMIT`, `IP6_NF_MATCH_RT` and
  `IP6_NF_MATCH_HL` off, one failing rule aborts the whole `*filter` restore, so the chains the
  following lines append to never exist. They are modules now, together with `CRYPTO_USER=m` for
  `/usr/lib/modules-load.d/bluez.conf`'s `crypto_user`, which every boot logged as `Failed to find
  module 'crypto_user'` (kernels/mediatek-mt81/PROVENANCE.md records the three edits).
- **The SDDM greeter cannot log anyone in on a first boot, and the journal says nothing.** `sddm`
  starts, the Wayland greeter connects (`Message received from greeter: Connect`) and then not one
  more line: no `[PAM] Authenticating`, no failure, for any account, while the same passwords work on
  tty1. Omarchy's theme has no user field; it calls `sddm.login(userModel.lastUser, ...)`
  (`default/sddm/omarchy/Main.qml`), and `lastUser` comes from `/var/lib/sddm/state.conf`, which did
  not exist -- so the greeter sends an empty user, which SDDM refuses before its socket server ever
  logs the `Login` message the report was looking for. Upstream writes that file in
  `omarchy-provision-owner`'s `configure_login()`, because on a real Omarchy machine the owner
  account is *created* at first boot. This port ships the owner in the image, so `build-rootfs.sh`
  writes the same file (`[Last] User=omarchy`, `Session=omarchy.desktop`, the session that
  `/usr/local/share/wayland-sessions/omarchy.desktop` provides). The one-boot autologin upstream
  writes beside it is deliberately not shipped: it exists because upstream's owner has just typed a
  password in the wizard, and this image's accounts are the documented ones (plan §3, decision 8).
- **The `[platform]` key does not survive the first boot, because that boot remakes the keyring.**
  `build-rootfs.sh` imports `platform.pub` and `--lsign`s it, and the report still FAILs. The image
  carries no pacman master key on purpose (every machine would share one), so the first boot runs
  `pacman-key --init && pacman-key --populate` -- the request `install/post-install/pacman.sh` leaves
  in the manifest, run by `omarchy-provision-hardware` -- into a fresh keyring, and only what is
  installed under `/usr/share/pacman/keyrings` comes back: the card keeps Omarchy's key and loses
  ours. The key is now shipped the way `omarchy-keyring` ships `omarchy.gpg`, as
  `/usr/share/pacman/keyrings/omarchy-platform.gpg` plus `omarchy-platform-trusted` naming its
  fingerprint, which is what `--populate` with no keyring name reads.
- **Two readings are of a different boot, and one pattern was simply wrong.** The `no swap` FAIL and
  the `ufw is not active` warn belong to the first boot; in the next one swap is up on `/dev/zram0`
  (priority 100, zstd, 3.7 GiB) and ufw is filtering on the rules it did manage to load. That also
  settles a design question: `/etc/systemd/zram-generator.conf` does not exist and does not need to,
  because zram-generator's own unit reads the drop-in
  `/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf` alone. The swap FAIL was the check's test,
  not the machine's -- `test -s` on a procfs file, answered below -- and the keyd warn was the script:
  it looked for `matched|device added` while keyd 2.6 logs `DEVICE: match 0000:0000:af5c732c
  /etc/keyd/default.conf (cros_ec)` and then creates `keyd virtual keyboard`. The check asks for that
  device first now, with the log as its fallback.

**The second card (2026-10-17) changed the question.** Its report came from the desktop session, so
there are no skips: SDDM logs in, Hyprland runs, and every fix the first card's mapping asked for is
visible from inside it -- `[platform]` trusted, `ufw is active`, keyd's virtual keyboard present. Its
three FAILs are two things: the same `no swap` line the first boot printed, which was the check's
`test -s` (below), and two of the seeding cause (the missing shell and the missing sleep monitor).

The cause: the user's home was never seeded from `/etc/skel`. `build-rootfs.sh` creates the account
before `omarchy-apply-system --install-user` installs the packages whose skel content that account
would need (the phase needs the account to exist, so the order cannot simply be reversed), and
nothing copied skel afterwards. On the card `~/.config/hypr/` therefore held only the file Hyprland
autogenerates for a user with no configuration -- `-- AUTOGENERATED HYPRLAND CONFIG`, 12644 bytes --
with no `autostart.lua` and none of Omarchy's defaults. `default/hypr/autostart.lua` is where
`hl.exec_cmd("omarchy-provision-first-run")` lives, and that is what enables the user units
(`install/user/first-run/enable-user-units.sh`: bt-agent, owed, the sleep lock, fcitx5, crash watch),
so one missing directory is the missing shell, the missing sleep monitor and the disabled sleep lock
at once. The image now seeds skel the way `useradd -m` would (leaving existing files alone), and the
Hyprland check no longer passes on any directory: it wants Omarchy's bootstrap in `hyprland.lua` and
says so when it finds Hyprland's own.

**Swap, and the two FAILs that were the check's.** `test -s` cannot test a procfs file: measured on
this kernel (7.2.7-mt81, the same one the cards run), `stat -c %s /proc/swaps` is `0` and
`[ -s /proc/swaps ]` is *false* on a machine whose `/dev/zram0` is active at priority 300, while
`wc -c < /proc/swaps` reads 105 bytes and `cat` shows the header and the entry. Both first boots
therefore failed `[ -s /proc/swaps ]` with swap up and busy, and neither the first card's diagnostics
(that card's *second* boot, its unit "since 09:52:41") nor the third card's `ok` was ever a change of
state -- the two earlier FAILs were a broken test, and the check now counts entries by *reading* the
file and, when there are none, puts the bytes it reads, the unit's state and its last log lines in
the FAIL itself.

**The third card (2026-10-17) is the acceptance's report, one check-fix away.** Everything the
mapping asked for is visible at once: 108 ok, 1 warn, 1 FAIL, 0 skip, with `the Quickshell shell is
running` and `the user's Hyprland configuration is Omarchy's` (the seeding above, doing what it was
supposed to), `omarchy-sleep-lock.service is enabled for this user` and the swap line green. Its one
FAIL was the check's own: it asked `pgrep -x omarchy-system-sleep-monitor`, and a process name is
truncated to 15 characters (`TASK_COMM_LEN`) -- measured: a script with that name runs as
`omarchy-system-` in `/proc/*/comm`, so the probe could not match it however well the monitor ran.
The check asks systemd for `omarchy-sleep-lock.service` now, and prints the state either way, so
whether the unit was in fact running on that boot is the re-run's to say rather than this
paragraph's. Its one warn was the check's too: it assumed a profile pinning an interface name had
been imported, and the maintainer's was made on the machine; the warn now fires only for a profile
older than the image's own manifest, which is the case that leaks a build host's Wi-Fi PSK instead
of describing a normal connection. The report also said `0 monitor(s) in the session` while `hyprctl`
had answered -- an empty `[]` would have failed the case just before it -- which is a third bug of
the same kind: the count assigned instead of accumulating, so a JSON that is not one line reports
whatever its last line held (measured over a two-line array with one `"name"`: 0 that way, 1 with
`+=`), and the pattern now comes in through `-v` rather than as a regex literal whose `\"` is not
portable between awks.

**Known noise, the same on the sibling's verified machine.** `bpf-restrict-fs: Failed to link
'restrict_filesystems' LSM BPF program: Operation not supported` (systemd's own program, with
`BPF_LSM=y` and `bpf` in `CONFIG_LSM`), the `sbs-battery` property failures, `mt6359-keys`/
`mt6359-accdet: Failed to locate of_node`, `i2c_hid_get_input: IRQ triggered but there's no data`,
`rt5682 ... ASoC: source widget I2S1 overwritten`, `[Firmware Bug]: VHE-capable CPU without EL2
virtual timer interrupt` and `coreboot_table ... probe ... failed with error -22` are this hardware's,
not this port's.

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