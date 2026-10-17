# Release notes

One file per release, named after its tag (`v0.1.0.md`), written by hand and versioned like
everything else: it is reused for the annotated tag and for whatever the release is published on.
`scripts/make-release.sh` does not generate it.

It exists so that the things a user cannot find out from the artifacts are written down somewhere.
What belongs in it:

- **What the release is**: the device, the Omarchy version and channel (`edge`), the kernel
  (`linux-omarchy-book`) and the commit it was built from — all of it already in the release's
  `RELEASE-INFO.txt`, which is the machine-readable half.
- **The assets** and what each one is for: `<device>.img.xz` (write it to a card with
  `xz -dc … | sudo dd of=<card> bs=4M conv=fsync`), `<device>-rootfs.tar.zst` (write a card from an
  extracted copy with `sudo ROOTFS=<dir> scripts/write-sd.sh <card>`),
  `<device>.vmlinuz.kpart` (the kernel partition of *that* image), and `platform/` (the bundle as a
  repository; see its own README).
- **How a machine already running this port updates.** With the release's `platform/` served
  somewhere and `[platform] Server = <url>` in `/etc/pacman.conf`, `sudo pacman -Sy && sudo pacman -Su`.
  Without that line the image has no repository for its own kernel or platform packages at all, and
  the only way forward is a new image (`PLATFORM_REPO_URL` is the build input that changes that).
- **The passwords.** Every image of this port carries accounts with a password set: `root` and
  `alarm` as Arch Linux ARM ships them (uid 0 and uid 1000, `alarm` in `wheel`), and `omarchy`
  (uid 1001, `wheel`) with the password `build-rootfs.sh` was given. `make-release.sh` prints them
  when it publishes. The release notes have to say it out loud: change them at first login, or lock
  the accounts, before the machine sees a network. Leaving the `alarm` account in place is a
  deliberate decision (plan §3, decision 8), not an oversight.
- **Anything a first boot needs to know**: which card the machine boots from (the eMMC is
  depthcharge's default; the card needs Ctrl+U), what the first boot finishes (the hardware leaves
  Omarchy deferred during the image build), and where `scripts/check-system.sh`'s report from real
  hardware lives (`reports/`).
