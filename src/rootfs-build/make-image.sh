#!/bin/bash
# Assemble a configured Debian arm64 ext4 image for RG Rotate, fully unprivileged.
# Extraction + overlay + mke2fs run inside one fakeroot session so file ownership
# and setuid bits from the tarball are preserved in the resulting ext4.
set -euo pipefail
cd "$(dirname "$0")"

TAR=$(readlink -f debian-bookworm-arm64.tar)
IMG=$(readlink -f debian-userdata.img)
IMG_MB=${IMG_MB:-4096}
ROOT_PART=/dev/mmcblk3p74
STAGE=$(mktemp -d)

cleanup(){ rm -rf "$STAGE"; }
trap cleanup EXIT

export TAR IMG IMG_MB ROOT_PART STAGE

fakeroot -- bash -e <<'FAKE'
S="$STAGE"
tar -C "$S" --numeric-owner -xf "$TAR"

# --- console: autologin root on the USB gadget serial ---
mkdir -p "$S/etc/systemd/system/serial-getty@ttyGS0.service.d"
# --autologin root + a SINGLE fixed baud, no --keep-baud / no baud list: on a
# CDC-ACM gadget --keep-baud made agetty adopt the host's line-coding and a comma
# baud list put it in baud-cycling + parity-detect mode, which garbled ttyGS0
# input (stuck echo char / reprinted banner fragments). Dropped the -o issue
# string too (redundant under autologin).
cat > "$S/etc/systemd/system/serial-getty@ttyGS0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --noissue 115200 %I $TERM
EOF
mkdir -p "$S/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
  "$S/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"

# --- fstab / hostname ---
cat > "$S/etc/fstab" <<EOF
$ROOT_PART  /  ext4  defaults,noatime,errors=remount-ro  0 1
EOF
echo "rgrotate" > "$S/etc/hostname"
printf '127.0.0.1\tlocalhost rgrotate\n' > "$S/etc/hosts"

# --- passwordless root (dev board); autologin handles the console anyway ---
sed -i 's#^root:[^:]*:#root::#' "$S/etc/shadow"

# --- USB peripheral role at boot ---
cat > "$S/etc/systemd/system/usb-device-role.service" <<'EOF'
[Unit]
Description=Force USB peripheral role for gadget console
DefaultDependencies=no
Before=sysinit.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for r in /sys/class/usb_role/*/role; do echo device > "$r" 2>/dev/null; done'
[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$S/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/usb-device-role.service \
  "$S/etc/systemd/system/sysinit.target.wants/usb-device-role.service"

# --- don't block boot on network ---
ln -sf /dev/null "$S/etc/systemd/system/systemd-networkd-wait-online.service"

# --- watchdog handoff: one service owns both watchdogs (AP wd0 + sc2730 wd1).
# The initramfs petters are killed before switch_root, so this service must take
# over immediately; systemd's own RuntimeWatchdog is left off to avoid contending
# for /dev/watchdog0 with this service.
cat > "$S/etc/systemd/system/hw-watchdog.service" <<'EOF'
[Unit]
Description=Feed hardware watchdogs (wd0 AP + wd1 sc2730)
DefaultDependencies=no
Before=sysinit.target shutdown.target
Conflicts=shutdown.target
[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -c /dev/watchdog0 && test -c /dev/watchdog1'
ExecStart=/bin/sh -c 'exec 8>/dev/watchdog0 9>/dev/watchdog1; while :; do printf x >&8; printf x >&9; sleep 2; done'
Restart=always
RestartSec=1
[Install]
WantedBy=sysinit.target
EOF
ln -sf /etc/systemd/system/hw-watchdog.service \
  "$S/etc/systemd/system/sysinit.target.wants/hw-watchdog.service"

# --- build the ext4 image from the staged tree (fakeroot preserves ownership) ---
rm -f "$IMG"
mke2fs -q -t ext4 -L rootfs -d "$S" -F "$IMG" "${IMG_MB}M"
FAKE

echo "Built: $IMG"
ls -lh "$IMG"
