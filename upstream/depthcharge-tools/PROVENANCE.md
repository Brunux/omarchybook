# Vendored `depthcharge-tools` recipe

Copied, not submoduled (docs/plan.md §3, decision 6): each repository must build
and release from its own HEAD.

Source: the AUR, `https://aur.archlinux.org/depthcharge-tools.git`, commit
`9f20e678ed63f4b9f20e82ace555577c0c88c7b5` (2024-01-05, the repository's only
commit; retrieved 2026-10-16). `pkgver`, `pkgrel`, `source` and the `sha256sums`
entry are unchanged.

Why it is vendored: the device rewrites its own kernel partition on every kernel
or initramfs change (the signed depthcharge FIT in p1), and `depthchargectl` is
what builds that FIT. `depthcharge-tools` is AUR-only — deliberately absent from
Arch Linux ARM, whose `vboot-utils` carries only `cgpt`/`futility`/`vbutil_*` —
so the recipe has to travel with this repository for a clean `$BUILD_ROOT` to be
able to rebuild the bundle (docs/recon.md §7, plan §8). It is the only package in
`[platform]` that is neither ours nor Omarchy's.

One deviation from the AUR original: `python-setuptools` is listed as a
makedepend (`python setup.py install` fails in a clean ALARM chroot without it).
The AUR's `# The actual checksum will be different` comment on `sha256sums` is
stale — the value is correct, verified by downloading the tag tarball.

Build with `scripts/build-package.sh upstream/depthcharge-tools`, which publishes
it into `[platform]` signed with the build key (see `keys/README.md`).

SHA-256:

```
a40602c38f275d5588ba61adb08eb28849e47a048a007ede451a6cbccf62c26d  PKGBUILD
```
