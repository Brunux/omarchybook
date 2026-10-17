# reports/

One file per boot worth keeping (docs/plan.md Phase 7). A report is the output of
`scripts/check-system.sh` on a booted card, kept because something in it was worth
learning from: the first boot that works, a boot that failed and what it said, a
boot after a change.

Nothing has booted on hardware yet, so this directory is empty on purpose.

## Making one

From the desktop session of the booted system, with this repository checked out
somewhere (a USB stick, `/home/omarchy` or a copy over SSH):

```sh
scripts/check-system.sh /path/to/omarchybook | tee reports/<date>-<what>.txt
```

A card written by `scripts/write-sd.sh` does **not** carry this repository (only
the boot and platform packages are shipped to the device), but the machine that
wrote it is the same machine: the checkout is on the internal disk, so boot the
card, log in as `omarchy`, mount the internal disk and run the script from there.

```sh
sudo mount /dev/mmcblk0p3 /mnt            # the internal disk, not the card
cd /mnt/home/brunux/Dev/omarchybook
scripts/check-system.sh "$PWD" | tee reports/$(date +%Y-%m-%d)-first-boot.txt
```

`check-system.sh` reads only; it changes nothing. Pass the checkout so it can also
compare the package manifests with the system. Run it as the desktop user: the
session and audio checks belong to that user, and the privileged reads go through
passwordless `sudo -n`.

## What a report has to carry

- The header line (`check-system` prints date, kernel and user), so two reports can
  be told apart without guessing which kernel produced them.
- The verdict line, and every `FAIL` line with the cause it was mapped to. Phase 7's
  acceptance is *a report with no FAIL, and every FAIL mapped to a known regression
  rather than a hypothetical*, so a report that is kept has to say which it is.
- Anything the report cannot see: whether the card was written by `write-sd.sh` or
  installed to eMMC, which release (if any) it came from, and what was changed by
  hand on the device afterwards.

## What must never be in here

A report of a rootfs, a chroot or a build host: the live sections stand down there
and the file would describe the wrong machine. `check-system.sh` says so when it
happens, and the report is worthless — do not keep it. Reports are also English
only, like every other versioned artifact in this repository.
