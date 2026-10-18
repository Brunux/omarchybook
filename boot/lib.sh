# shellcheck shell=bash
# The boot-chain scripts in this directory source a lib that sits beside them
# (make-kpart.sh, install-kpart.sh), because platform/omarchy-book-boot ships
# those same files to the device, where lib.sh is the packaged device-side one
# instead of the build host's.
#
# In this repository the lib is scripts/lib.sh: it knows how to find a checkout,
# a device and a built rootfs, which is what the build-host callers need.
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
