# Vendored `omarchy-pkgs` recipes

Copied, not submoduled (docs/plan.md §3, decision 6): each repository must build
and release from its own HEAD.

Source: `https://github.com/omacom/omarchy-pkgs.git`, branch `master`, commit
`aad6d434558c1679520062e1188a4cfc22c7afd0` (retrieved 2026-10-16).

Only the recipes the build actually runs are vendored:

| Path | Why |
|---|---|
| `pkgbuilds/omarchy-dev/` | builds the Omarchy runtime from a pinned quattro checkout (`OMARCHY_SRC`), which is how the vendored `aarch64-google` patch is applied |
| `pkgbuilds/omarchy-settings-dev/` | the settings half of the same checkout; it ships a second copy of the platform detector for the pacman platform guard |

Both are the `-dev` recipes on purpose. `omarchy`/`omarchy-settings` are built
from `basecamp/omarchy` at the released tag, which predates the platform
detection this port patches; the `-dev` recipes are pinned to the quattro tip
(`4.0.0.r7026.g51bfd1d`) and take a local source tree instead. `omarchy-nvim`
ships unpatched and is installed from `[omarchy]`, so it is not vendored.

SHA-256:

```
5c9398e933c0e1c7f8a9c22fe790a11c39c308dbae0fcc6379230bbff6c69107  pkgbuilds/omarchy-dev/PKGBUILD
c38dc571f9171d113685b1b981daa46c8485494efa231f6be1df5dc41f8dc740  pkgbuilds/omarchy-settings-dev/PKGBUILD
50e40353caa64a852c0b5919cadd7c1eabf48da2a0b5cf86d92614958c5123e3  pkgbuilds/omarchy-settings-dev/omarchy-settings-dev.install
```

Refresh with `git fetch` in a checkout of `omacom/omarchy-pkgs` and re-read the
`_commit`/`pkgver`/sha256sums the recipes pin; keep that pin identical to
`OMARCHY_COMMIT` in `scripts/lib.sh`.
