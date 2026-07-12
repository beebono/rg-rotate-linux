#!/bin/bash
# Produce the Debian 13 (trixie) arm64 base rootfs tarball that make-image.sh
# consumes. Fully unprivileged via mmdebstrap (no root, no qemu binfmt needed
# for the foreign-arch download+extract path).
#
# Output: debian-trixie-arm64.tar  (input to make-image.sh)
#
# Override SUITE / MIRROR / ARCH / PACKAGES via the environment.
set -euo pipefail
cd "$(dirname "$0")"

SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-arm64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
OUT="${OUT:-debian-${SUITE}-${ARCH}.tar}"
# Per-device config (console, watchdog, fstab, USB role) is layered in by
# make-image.sh, not baked into the base tar. This set covers a working CLI
# board: base system + networking, an audio stack for the DAC/DSP bring-up work,
# Python, and the usual hardware-poking/debug amenities.
#
# Auto-connect note: network-manager brings up WiFi/wired automatically once a
# connection profile exists. NM ignores interfaces listed in
# /etc/network/interfaces, so the two coexist; the actual WiFi credentials
# (an NM keyfile under /etc/NetworkManager/system-connections/ or a
# wpa_supplicant.conf) are layered in per-device by make-image.sh, not here.
PACKAGES="${PACKAGES:-\
systemd-sysv,udev,dbus,\
ifupdown,iproute2,iputils-ping,isc-dhcp-client,\
network-manager,wpasupplicant,iw,wireless-tools,rfkill,\
openssh-server,ca-certificates,\
bluez,bluez-tools,\
evtest,libinput-tools,evemu-tools,joystick,input-utils,\
iperf3,tcpdump,ethtool,\
fio,memtester,stress-ng,\
nano,less,vim-tiny,file,tmux,htop,\
python3,python3-pip,\
alsa-utils,alsa-tools,libasound2,\
usbutils,i2c-tools,pciutils,\
device-tree-compiler,kmod,\
gpiod,\
strace,ltrace,gdb,xxd,lsof,psmisc,\
curl,wget,rsync,\
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
