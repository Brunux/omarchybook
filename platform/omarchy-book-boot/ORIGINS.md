# Origins of the files in this package

The package is this repository's own, but almost everything it installs is a
port, so this records from where and what changed (plan §2.5).

**The boot chain** — `install-kpart.sh`, `make-kpart.sh` and `lib-cgpt.sh` —
comes from `debian-aarch64` (v0.1.0, hardware-verified on this machine). They
are deliberately *not* copies kept here: the canonical files live in the
repository's `boot/` and the builder stages them (`extra.list`), so a kpart
built on the device uses the same logic as one built on the build host, and a
change in either place rebuilds the package.

Three things changed in the port:

- `install-kpart.sh` sources `lib.sh` and calls `make-kpart.sh` from beside
  itself, and this package ships its own device-side `lib.sh` in place of the
  repository's build-host one (`boot/lib.sh`, a wrapper around
  `scripts/lib.sh`). The three ported scripts are otherwise unmodified.
- `dd` runs with `status=none`: the Debian original let it print its own
  progress, which is noise inside a pacman hook.
- The chroot guard actually works. The original wrote
  `[ "$(stat -c %d:%i /)" = "$(stat -c %d:%i /proc/1/root)" ]`, which can never
  be true — `stat` does not dereference the last component, so it reports the
  procfs symlink itself — and would have let a chroot rewrite the *host's*
  kernel partition. `boot/lib-cgpt.sh` now owns the check and uses `stat -L`.
  The sibling project has the same bug (docs/recon.md §12).

**The keys** — `devkeys/` are ChromiumOS' well-known developer keys, vendored
from `vboot_reference` (`10343b821`) with their provenance in
`boot/devkeys/README.md`. ALARM's `vboot-utils` ships none, and
`depthchargectl` takes the three files explicitly (`--vboot-keyblock`,
`--vboot-public-key`, `--vboot-private-key`). They are the right keys to sign
with because the machine boots dev-signed (`dev_boot_signed_only=0`).

**The device facts** — `deviceinfo` and `kernel-cmdline.conf` are the
repository's `devices/google-asurada/` files, staged in by the builder. The
packaged `lib.sh` derives the board, the DTB glob, the partition geometry and
the command line from them, so nothing device-specific is typed twice.

**Written for this port** — the two entrypoints, `/usr/bin/omarchy-book-boot`,
the ALPM hook's trigger (`boot/99-omarchy-kpart.hook`) and the tests.
