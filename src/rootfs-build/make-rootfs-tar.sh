#!/bin/bash
# Produce the Debian 12 (bookworm) arm64 base rootfs tarball that make-image.sh
# consumes. Fully unprivileged via mmdebstrap (no root, no qemu binfmt needed
# for the foreign-arch download+extract path).
#
# Output: debian-bookworm-arm64.tar  (input to make-image.sh)
#
# Override SUITE / MIRROR / ARCH / PACKAGES via the environment.
set -euo pipefail
cd "$(dirname "$0")"

SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
OUT="${OUT:-debian-${SUITE}-${ARCH}.tar}"
# Per-device config (console, watchdog, fstab, USB role) is layered in by
# make-image.sh, not baked into the base tar. This set covers a working CLI
# board: base system + networking, an audio stack for the DAC/DSP bring-up work,
# Python, and the usual hardware-poking/debug amenities.
PACKAGES="${PACKAGES:-\
systemd-sysv,udev,dbus,\
ifupdown,iproute2,iputils-ping,isc-dhcp-client,\
wpasupplicant,openssh-server,ca-certificates,\
nano,less,vim-tiny,file,tmux,htop,\
python3,python3-pip,\
alsa-utils,alsa-tools,libasound2,\
usbutils,i2c-tools,pciutils,\
device-tree-compiler,kmod,\
gpiod,evtest,\
strace,gdb,xxd,\
curl,wget,rsync,ethtool,\
bash-completion}"

command -v mmdebstrap >/dev/null || {
  echo "ERROR: mmdebstrap not found. Install it: sudo apt install mmdebstrap" >&2
  exit 1
}

mmdebstrap \
  --arch="$ARCH" \
  --variant=minbase \
  --include="$PACKAGES" \
  "$SUITE" "$OUT" "$MIRROR"

echo "Built: $OUT"
ls -lh "$OUT"
echo "Next: ./make-image.sh   (assembles the configured ext4 userdata image)"
