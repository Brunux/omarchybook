# Vendored signing keys

Keys that are a build input rather than a package dependency.

## `omarchy.gpg`

The Omarchy package signing key. `[omarchy]` (`https://pkgs.omarchy.org/edge/$arch`)
signs its database and packages with it, and Arch Linux ARM's keyring does not
carry it, so `build-rootfs.sh` imports and locally signs it before installing
anything from that repository (the ISO does the same from its own copy).

```
pub   ed25519 2025-08-28 [SC]
      40DFB630FF42BCFFB047046CF0134EE680CAC571
uid                      Omarchy <pkgs@omarchy.org>
sub   cv25519 2025-08-28 [E]
      2839BEED54A8B49AB60BA862FF4700E516FCE0A8
```

Source: `omacom/omarchy-iso`, branch `quattro`, commit `43cf0490`, file
`builder/omarchy.gpg`. SHA-256:

```
15d6aac44df688165b2ea35fe0b23af239bbc66a6909c10a5c219e8d94b707de  omarchy.gpg
```

Once `omarchy-keyring` is installed the populated keyring supersedes this copy;
the vendored file only bootstraps trust in `[omarchy]`.
