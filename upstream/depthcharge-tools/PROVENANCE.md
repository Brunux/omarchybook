# Vendored `depthcharge-tools` recipe

Copied, not submoduled (docs/plan.md §3, decision 6): each repository must build
and release from its own HEAD.

Source: the AUR, `https://aur.archlinux.org/depthcharge-tools.git`, commit
`9f20e678ed63f4b9f20e82ace555577c0c88c7b5` (2024-01-05, the repository's only
commit; retrieved 2026-10-16). `pkgver`, `pkgrel`, the upstream `source` and its
`sha256sums` entry are unchanged.

Why it is vendored: the device rewrites its own kernel partition on every kernel
or initramfs change (the signed depthcharge FIT in p1), and `depthchargectl` is
what builds that FIT. `depthcharge-tools` is AUR-only — deliberately absent from
Arch Linux ARM, whose `vboot-utils` carries only `cgpt`/`futility`/`vbutil_*` —
so the recipe has to travel with this repository for a clean `$BUILD_ROOT` to be
able to rebuild the bundle (docs/recon.md §7, plan §8). It is the only package in
`[platform]` that is neither ours nor Omarchy's.

## Why this recipe is not the AUR one verbatim

The AUR recipe builds the 2021 release on a 2021 system. Three things had to be
fixed for it to work on ALARM's python 3.14 and in a real rootfs (all three found
by running the boot chain in a built rootfs, docs/recon.md §12):

1. `0001-argparse-nargs-zero.patch` — `depthcharge_tools/utils/argparse.py`
   builds positionals with `nargs=0`, which 3.14's argparse rejects. The parser
   is class-level and built at import time, so even `depthchargectl --version`
   died. Cherry-picked from upstream master.
2. `0002-drop-pkg_resources.patch` — `depthcharge_tools/__init__.py` imported
   `pkg_resources` at import time. `python-setuptools` no longer ships
   `pkg_resources` at all (84.0.0 has none), so the module could not load.
   Upstream replaced it with `importlib.metadata`/`importlib.resources` and
   `packaging.version`; this is that fix, cherry-picked from upstream master.
   Both patches are upstream's own (`1c123c8`, retrieved 2026-10-17), and only
   the compatibility fixes are taken — not the ~40 behaviour commits after them,
   because the boot chain in `debian-aarch64` (verified on this hardware) was
   built with 0.6.2's semantics and a differently-built FIT is not something to
   discover on the device.
3. `depends` also names the *programs* the tool runs: `dtc` (`fdtget`/`fdtput`),
   `vboot-utils` (`futility`/`vbutil_kernel`/`cgpt`) and `uboot-tools`
   (`mkimage`), plus `python-packaging` for fix 2. The AUR declares only
   `python`, so a build dies on the first one it happens to need — first
   `fdtget`, then `mkimage`, as the FIT is assembled. `python-setuptools` stays a
   **makedepend** only (`python setup.py install` fails in a clean ALARM chroot
   without it). The other programs upstream's README lists are for other paths
   or other boards: this one's FIT uses `lzma` (from `xz`, already installed),
   and `crossystem` (not packaged on Arch) is only for the crossystem
   subcommands, never for a build.

The package keeps `pkgrel=1`: like every other package in `[platform]`, it is
republished content-addressed, and `scripts/build-rootfs.sh` refreshes the pacman
cache from the bundle so the new bytes are picked up. The AUR's `# The actual
checksum will be different` comment on `sha256sums` is stale — the value is
correct, verified by downloading the tag tarball.

Build with `scripts/build-package.sh upstream/depthcharge-tools`, which publishes
it into `[platform]` signed with the build key (see `keys/README.md`).

SHA-256:

```
e51cafe6612389dbf95201dde6001a44443926b0471390f3bd3716f25a95d98d  PKGBUILD
24b49f5a88054441029ea94f7f8f512e10f450d3440e47a299bfb03369d8a6a0  0001-argparse-nargs-zero.patch
d07aabb3c87576503b54b19c415acba4b55db8de94ef66643e09393837737ed7  0002-drop-pkg_resources.patch
```
