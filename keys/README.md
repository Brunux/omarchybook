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

## Our own key is *not* here

`[platform]` — the local bundle this repository builds — is signed with a
build/release key of its own, and a private key is never committed. It is
created on first use and lives beside the build:

```
~/.cache/omarchybook/keys/gnupg/       # keyring (mode 700, root-owned)
~/.cache/omarchybook/keys/platform.pub # public half, for a build to trust
uid                                    # Omarchy Book Build <build@omarchybook.invalid>
```

`lib.sh`'s `ensure_platform_key` generates it (no passphrase, `ed25519`, sign
only) if it is absent, and `sign_platform_packages` writes a binary detached
signature next to every package in the bundle. `build-rootfs.sh` imports
`platform.pub` into the image's keyring and locally signs it, which is what lets
`[platform]` inherit the global `SigLevel` — signatures required, database
optional — instead of the `TrustAll` a build-time bundle would otherwise need.
The private key never enters the rootfs: indexing reads the signatures from disk
with `repo-add`, it does not sign the database.

Deleting `~/.cache/omarchybook/keys` therefore invalidates every published
signature: the next build generates a new key and re-signs the bundle (the image
is rebuilt against it in the same run, so nothing is left verifying against a
key that is gone). A *release* key, published with the release so a device can
verify a `[platform]` repository later (docs/recon.md §8), is a deliberate
out-of-tree input and does not exist yet.
