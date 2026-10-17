# Provenance

Vendored from the sibling repository `~/Dev/debian-aarch64` at commit
`477956240a1f7eb0ca702ba96cc5f0ec03e4f2c8` (v0.1.0, released and verified on the
Hayato hardware). That repository is the working Debian port for the same machine;
this one reuses its kernel and device knowledge instead of rediscovering it
(plan §2.5).

Copied unchanged: `version` (7.2.7), `patches/` (the `series` order is
authoritative), and `APKBUILD.reference`.

`config.aarch64` is the sibling's, with what Omarchy's own system needs added:
`NETFILTER_XT_MATCH_LIMIT`, `IP6_NF_MATCH_RT` and `IP6_NF_MATCH_HL`, whose
absence made `ufw` fail at boot (its `before6.rules` appends `-m rt`/`-m hl`
rules and `before.rules` `-m limit` logging rules), and `CRYPTO_USER`, which
`/usr/lib/modules-load.d/bluez.conf` asks for and the image logs as a failure to
find (docs/recon.md §14).

`APKBUILD.reference` is the upstream **postmarketOS (pmaports)**
`linux-postmarketos-mediatek-mt81` recipe, kept for reference only. The Arch
kernel package is `linux-omarchy-book` (plan §3), a separate PKGBUILD modelled on
upstream Omarchy's `linux-omarchy`.

These files are shared knowledge, not scratch copies: change them here only when
the change belongs to this port (Arch packaging, a newer kernel), and do not let
them silently drift from the Debian source.
