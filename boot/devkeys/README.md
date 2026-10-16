# Vendored vboot developer keys

`depthchargectl build` signs the FIT with the **vboot developer keys**. On
Debian these come from the `vboot-kernel-utils` package; the Arch Linux ARM
`vboot-utils` package (which provides `cgpt`, `crossystem` and `futility`)
**does not ship them** (confirmed in `docs/recon.md` §7). So this repository
vendors them here, and `boot/make-kpart.sh` passes
`--keydir <this directory>`.

Expected files (the names `depthchargectl` looks for, `vboot_keys()` in
depthcharge-tools `utils/platform.py`):

```
kernel.keyblock
kernel_data_key.vbprivk
kernel_subkey.vbpubk
```

These are the **public, well-known ChromeOS developer keys** from
`chromiumos/platform/vboot_reference` (`tests/devkeys/`), not real secrets —
every depthcharge developer-mode device uses them. Still, fetch them from the
pinned vboot revision rather than trusting a random copy, and record the source
revision here.

Status: **not vendored yet.** `boot/make-kpart.sh` warns and falls back to
`depthchargectl`'s own key search when this directory is empty, so the build
cannot produce a signed kpart until the keys land here. Vendoring them is part
of Phase 5 (docs/plan.md), together with the install step that places them at
`/usr/share/vboot/devkeys` on the device.
