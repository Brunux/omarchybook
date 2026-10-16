# Provenance

Vendored from the sibling repository `~/Dev/debian-aarch64` at commit
`477956240a1f7eb0ca702ba96cc5f0ec03e4f2c8` (v0.1.0, released and verified on the
Hayato hardware). That repository is the working Debian port for the same machine;
this one reuses its kernel and device knowledge instead of rediscovering it
(plan §2.5).

Copied unchanged: `version` (7.2.7), `config.aarch64`, `patches/` (the `series`
order is authoritative), and `APKBUILD.reference`.

`APKBUILD.reference` is the upstream **postmarketOS (pmaports)**
`linux-postmarketos-mediatek-mt81` recipe, kept for reference only. The Arch
kernel package is `linux-omarchy-book` (plan §3), a separate PKGBUILD modelled on
upstream Omarchy's `linux-omarchy`.

These files are shared knowledge, not scratch copies: change them here only when
the change belongs to this port (Arch packaging, a newer kernel), and do not let
them silently drift from the Debian source.
