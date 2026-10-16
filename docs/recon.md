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
  hooks are what had to be disabled** in `debian-aarch64`; the AUR recipe installs only the Python
  package, so it appears to ship no `/etc/kernel/postinst.d` hooks — **still to confirm after a
  native build**, and disabled if present.
- **`vboot-utils` 154.16805-1**: `arch=(i686 x86_64)` — **x86-only in the recipe**, so a native
  aarch64 build needs `makepkg --ignorearch` (or a patched `arch=`) and `depends=(acpica cbfstool
  chromeos-flashrom-git libutil-linux libzip openssl)`. The PKGBUILD explicitly installs
  `/usr/share/vboot/devkeys` (copied from `tests/devkeys`), and `make install MINIMAL=1` ships
  `futility`. **Confirm both after building.** This is the one AUR dependency (`chromeos-flashrom-git`)
  that may itself need a native build.
- **`vboot-kernel-utils` is not in the AUR** — on Arch, `futility` and the devkeys come from
  `vboot-utils`, unlike Debian where `cgpt` and `futility` are separate packages.

Everything AUR-only that is needed on the device gets built once and published into the local
`[platform]` bundle (`repo-add`), per plan §7.

## Still open (need a chroot or hardware — not answerable read-only)

1. Confirm the built `depthcharge-tools` installs no kernel/initramfs hooks on Arch (disable if it does).
2. Confirm `vboot-utils` on aarch64 ships both `futility` and `/usr/share/vboot/devkeys`.
3. `pacman -U` / `mkinitcpio` behavior inside the Phase 1/2 chroot.
4. Whether LUKS is wanted later (plan §8) and whether the SD card must self-install to eMMC (assumed yes).
