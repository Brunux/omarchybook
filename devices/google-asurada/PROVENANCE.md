# Provenance

Vendored from the sibling repository `~/Dev/debian-aarch64` at commit
`477956240a1f7eb0ca702ba96cc5f0ec03e4f2c8` (v0.1.0, released and verified on the
Hayato hardware).

Copied unchanged: `deviceinfo`, `kernel`, `kernel-cmdline.conf`, `modules-initfs`.

`deviceinfo` is a pmaports-style, sourceable description of the Google Hayato
(ASUS Chromebook Detachable / Flip CM3 CM3200, MediaTek MT8192 `google-asurada`).
Our build scripts read `deviceinfo_dtb`, `deviceinfo_cgpt_kpart*` and
`deviceinfo_depthcharge_board` from it, so the values must keep matching what
`make-kpart.sh` builds.

`packages.list` is **not** vendored here: it holds Arch/ALARM package names,
which differ from the Debian names the sibling uses, and are settled in Phase 0/2
(plan §2.5, §9). Nothing here should reference Debian packages.
