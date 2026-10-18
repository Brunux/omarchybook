# Vendored vboot developer keys

`depthchargectl build` signs the FIT with the **vboot developer keys**. On
Debian these come from the `vboot-kernel-utils` package; the Arch Linux ARM
`vboot-utils` package (which provides `cgpt`, `crossystem` and `futility`)
**does not ship them** (confirmed in `docs/recon.md` §7). So this repository
vendors them here, and `boot/make-kpart.sh` passes
`--keydir <this directory>`.

These files (the names `depthchargectl` looks for, `vboot_keys()` in
depthcharge-tools `utils/platform.py`):

```
kernel.keyblock
kernel_data_key.vbprivk
kernel_subkey.vbpubk
```

They are the **public, well-known ChromeOS developer keys** from
`chromiumos/platform/vboot_reference` (`tests/devkeys/`), not real secrets —
every depthcharge developer-mode device uses them.

## Provenance

Fetched from the revision that Arch Linux ARM's `vboot-utils` is built from,
`r2729.10343b821` (docs/recon.md §7), so the keys and the `cgpt`/`futility`
on the device come from the same vboot snapshot:

```
revision: 10343b821
source:   https://chromium.googlesource.com/chromiumos/platform/vboot_reference/+/10343b821/tests/devkeys/
```

| File | sha256 |
|---|---|
| `kernel.keyblock` | `4e708c9ec43ac4a5d718474c9431ba6b6da3e64a9dda6afd2853a9e9e3079ffb` |
| `kernel_data_key.vbprivk` | `bc9e707a86e55a93f423e7bcdae4a25fd470b868e53829b91bbe2ccfbc6da27b` |
| `kernel_subkey.vbpubk` | `36b9c5fa6f5d0432b9acbe8e2b7da2e602162a87a425575c6d7ba975a0440708` |

## Device install

The keys are only developer-mode material and are not secrets, but the device
still needs them where `depthchargectl` searches (`docs/recon.md` §7):
`/usr/share/vboot/devkeys`. Shipping and placing them is part of the platform
boot package (`omarchy-book-boot`, Phase 5), not of the upstream Omarchy
proposal.
