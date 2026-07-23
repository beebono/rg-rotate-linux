#!/usr/bin/env bash
#
# Build a complete micro-SD Debian (trixie, arm64) image for RG Rotate that
# our vendor U-Boot boots via extlinux.
#
# Boot path: the SPL loads our custom U-Boot from the raw GPT-labeled "uboot"
# partition on the microSD, then that U-Boot's extlinux_diag scan (see
# board/spreadtrum/ums512_1h10/extlinux_diag.c) reads the FAT boot partition.
# The microSD is registered as `mmc 1`; the scan tries
# `mmc 1:2 /extlinux/extlinux.conf` FIRST, before the eMMC boot_a/boot_b slots.
#
# GPT layout. `uboot` is deliberately FIRST so the trailing rootfs can be grown
# in place later (e.g. `growpart`/`resize2fs`) without moving anything:
#   p1 = raw "uboot"  -> uboot_custom.img          (SPL loads it by GPT label)
#   p2 = FAT32 boot   -> /extlinux/extlinux.conf + /Image + /<dtb>  (u-boot reads)
#   p3 = ext4 rootfs  -> Debian                                     (kernel mounts)
#
# In Linux the SD is `mmcblk0` (ums512.dtsi: mmc0 = &sdio0; eMMC is mmc3), so
# the kernel root is /dev/mmcblk0p3.
#
# We ship the busybox initramfs on the boot partition (not a bare direct root):
# this board has NO broken-out UART, so the ONLY console is the USB g_serial
# gadget (ttyGS0). The initramfs init forces the USB peripheral role EARLY so
# the gadget enumerates, and — if the rootfs fails to mount — drops a recovery
# banner on ttyGS0 instead of a dead direct-root boot. The same init honors
# root= from the extlinux cmdline, so it switch_root's into /dev/mmcblk0p2.
#
# Fully unprivileged: the two filesystems are built as plain files (mkfs.vfat
# + mcopy; mke2fs -d under fakeroot to preserve ownership/setuid), the GPT is
# written with sfdisk on a regular file, and the raw u-boot image + filesystem
# images are dd'd into their partition offsets. No loop devices, no root, no sudo.
#
# Usage:
#   ./build_sdcard_debian.sh [out.img]
# Env overrides:
#   KERNEL_IMG DTB_IMG ROOTFS_TAR UBOOT_IMG   (inputs)
#   UBOOT_MB=16 BOOT_MB=128 ROOTFS_MB=3072    (partition sizes; total ~= sum + 2MiB align/tail)
#   CMDLINE                                    (kernel cmdline; sane default below)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_IMG="${1:-$SCRIPT_DIR/rg-rotate-sdcard.img}"

KERNEL_IMG="${KERNEL_IMG:-$REPO_ROOT/src/linux-7-1-sprd/arch/arm64/boot/Image}"
DTB_IMG="${DTB_IMG:-$REPO_ROOT/src/linux-7-1-sprd/arch/arm64/boot/dts/sprd/ums512-rg-rotate.dtb}"
ROOTFS_TAR="${ROOTFS_TAR:-$REPO_ROOT/src/rootfs-build/debian-trixie-arm64.tar}"
INITRD_IMG="${INITRD_IMG:-$REPO_ROOT/build/initramfs/initramfs.cpio.gz}"
# Raw custom U-Boot image (built by tools/scripts/build_vendor_uboot_img.sh),
# dd'd into the GPT-labeled "uboot" partition that the SPL loads.
UBOOT_IMG="${UBOOT_IMG:-$REPO_ROOT/build/boot/uboot_custom.img}"
AUDIO_DIR="${AUDIO_DIR:-$REPO_ROOT/tools/audio-testing}"
# AGDSP firmware. The built-in sprd-audcp-boot driver request_firmware()s this
# at probe (early boot, from the initramfs), but also drop it in the booted
# rootfs so a driver unbind/rebind or deferred probe after switch_root can still
# find it during audio debugging.
FW_DIR="${FW_DIR:-$REPO_ROOT/src/initramfs/overlay/lib/firmware}"

UBOOT_MB="${UBOOT_MB:-16}"
BOOT_MB="${BOOT_MB:-128}"
ROOTFS_MB="${ROOTFS_MB:-3072}"
ROOT_PART="/dev/mmcblk0p3"
# The initramfs init parses root= off this cmdline and switch_root's into it.
CMDLINE="${CMDLINE:-console=tty0 ignore_loglevel initrd=/init root=$ROOT_PART rw}"

# Optional WiFi auto-connect profile baked into NetworkManager. Set WIFI_SSID
# (and WIFI_PSK for WPA-PSK networks; leave PSK empty for an open network) to
# have the board associate + DHCP on boot with no console interaction. Unset =>
# no profile written; use nmtui/nmcli on-device instead.
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"

DTB_NAME="$(basename "$DTB_IMG")"

for f in "$KERNEL_IMG" "$DTB_IMG" "$ROOTFS_TAR" "$INITRD_IMG" "$UBOOT_IMG"; do
    [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; \
        [[ "$f" == "$INITRD_IMG" ]] && echo "  (build it: src/initramfs/build-initramfs.sh)" >&2; \
        [[ "$f" == "$UBOOT_IMG" ]] && echo "  (build it: tools/scripts/build_vendor_uboot_img.sh)" >&2; \
        exit 1; }
done
for cmd in sfdisk mkfs.vfat mmd mcopy mke2fs fakeroot truncate dd stat sha256sum tar; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing host tool: $cmd" >&2; exit 1; }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

MiB=$((1024 * 1024))
ALIGN_MB=1                                  # 1 MiB gap before p1 (room for primary GPT)
TAIL_MB=1                                   # 1 MiB gap after last part (room for backup GPT)
P1_START_MB=$ALIGN_MB                        # p1 = raw uboot
P2_START_MB=$((P1_START_MB + UBOOT_MB))      # p2 = FAT32 boot
P3_START_MB=$((P2_START_MB + BOOT_MB))       # p3 = ext4 rootfs
TOTAL_MB=$((P3_START_MB + ROOTFS_MB + TAIL_MB))

# The custom U-Boot image must fit inside the raw uboot partition.
UBOOT_BYTES=$(stat -c %s "$UBOOT_IMG")
if (( UBOOT_BYTES > UBOOT_MB * MiB )); then
    echo "uboot image ($UBOOT_BYTES bytes) exceeds uboot partition (${UBOOT_MB}MiB); raise UBOOT_MB" >&2
    exit 1
fi

echo "==> layout: p1 uboot ${UBOOT_MB}MiB @ ${P1_START_MB}MiB, p2 FAT32 ${BOOT_MB}MiB @ ${P2_START_MB}MiB, p3 ext4 ${ROOTFS_MB}MiB @ ${P3_START_MB}MiB (total ${TOTAL_MB}MiB)"

# ---------------------------------------------------------------------------
# 1. Boot filesystem (FAT32) — extlinux + kernel + dtb
# ---------------------------------------------------------------------------
BOOT_IMG="$tmpdir/boot.img"
truncate -s "$((BOOT_MB * MiB))" "$BOOT_IMG"
mkfs.vfat -F 32 -n RGROTATE_BT "$BOOT_IMG" >/dev/null

cat >"$tmpdir/extlinux.conf" <<EOF
DEFAULT linux
TIMEOUT 0

LABEL linux
    KERNEL /Image
    INITRD /initramfs.cpio.gz
    FDT /$DTB_NAME
    APPEND $CMDLINE
EOF

mmd   -i "$BOOT_IMG" ::/extlinux
mcopy -i "$BOOT_IMG" "$KERNEL_IMG"          "::/Image"
mcopy -i "$BOOT_IMG" "$DTB_IMG"             "::/$DTB_NAME"
mcopy -i "$BOOT_IMG" "$INITRD_IMG"          "::/initramfs.cpio.gz"
mcopy -i "$BOOT_IMG" "$tmpdir/extlinux.conf" "::/extlinux/extlinux.conf"
echo "==> boot fs built"

# ---------------------------------------------------------------------------
# 2. Root filesystem (ext4) — Debian base tar + device config, under fakeroot
# ---------------------------------------------------------------------------
ROOTFS_IMG="$tmpdir/rootfs.img"
STAGE="$tmpdir/staging"
mkdir -p "$STAGE"

export ROOTFS_TAR ROOTFS_IMG STAGE ROOTFS_MB ROOT_PART AUDIO_DIR FW_DIR
export WIFI_SSID WIFI_PSK

fakeroot -- bash -e <<'FAKE'
S="$STAGE"
tar -C "$S" --numeric-owner -xf "$ROOTFS_TAR"

# --- console: autologin root on the framebuffer VT (no UART on this board) and
#     on the USB gadget serial (ttyGS0). ---
for TTY in tty1 ttyGS0; do
  case "$TTY" in
    tty1)   SVC="getty@tty1.service";        BAUD="38400" ;;
    ttyGS0) SVC="serial-getty@ttyGS0.service"; BAUD="115200" ;;
  esac
  D="$S/etc/systemd/system/${SVC}.d"
  mkdir -p "$D"
  # NOTE: --autologin root + a SINGLE fixed baud, and NO --keep-baud / no baud
  # list. On a CDC-ACM gadget the "baud" is advisory, but --keep-baud made agetty
  # adopt whatever line-coding the host opened with and a comma baud list puts it
  # in baud-cycling + parity-detect mode -- which is what garbled ttyGS0 input
  # (echoed as a stuck char / reprinted "ttyGS0" banner fragments). Fixed 115200,
  # autologin, no login prompt, no parity guessing. Dropped the -o '-p -- \u'
  # login-issue string too: redundant under --autologin and pure garble surface.
  cat > "$D/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --noissue $BAUD %I \$TERM
EOF
done
mkdir -p "$S/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
  "$S/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"

# --- fstab / hostname / hosts ---
cat > "$S/etc/fstab" <<EOF
$ROOT_PART  /  ext4  defaults,noatime,errors=remount-ro  0 1
EOF
echo "rgrotate" > "$S/etc/hostname"
printf '127.0.0.1\tlocalhost rgrotate\n' > "$S/etc/hosts"

# --- passwordless root (dev board) ---
sed -i 's#^root:[^:]*:#root::#' "$S/etc/shadow"

# --- USB role is selected automatically by the Type-C port manager
# (sc27xx_pd) from CC detection; no forced-peripheral service, which would
# fight the TCPM and break host mode. The gadget console still comes up when
# plugged into a host (CC selects device). ---

# --- don't block boot on the network ---
ln -sf /dev/null "$S/etc/systemd/system/systemd-networkd-wait-online.service"

# --- NetworkManager: enable the service + (optionally) bake a WiFi auto-connect
#     profile. mmdebstrap's minbase variant doesn't run maintainer postinsts, so
#     enable the unit explicitly rather than relying on the systemd preset. ---
if [ -e "$S/lib/systemd/system/NetworkManager.service" ]; then
  mkdir -p "$S/etc/systemd/system/multi-user.target.wants"
  ln -sf /lib/systemd/system/NetworkManager.service \
    "$S/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

  if [ -n "$WIFI_SSID" ]; then
    NMDIR="$S/etc/NetworkManager/system-connections"
    mkdir -p "$NMDIR"
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    PROFILE="$NMDIR/${WIFI_SSID}.nmconnection"
    {
      printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' \
        "$WIFI_SSID" "$UUID"
      printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$WIFI_SSID"
      if [ -n "$WIFI_PSK" ]; then
        printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$WIFI_PSK"
      fi
      printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } > "$PROFILE"
    # NM refuses to load keyfiles that aren't root-owned 0600 (fakeroot records
    # this and mke2fs -d bakes it into the image).
    chmod 600 "$PROFILE"
    echo "==> baked WiFi profile for SSID '$WIFI_SSID'" >&2
  fi
fi

# --- watchdog handoff: feed AP wd0 + sc2730 wd1. The initramfs petters are
#     killed right before switch_root, so this service must take over early. ---
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

# --- bake the audio-testing kit into /root so findings can be exercised
#     on-device. The arm64 tone/mixer/i2c helpers go on PATH. ---
if [ -d "$AUDIO_DIR" ]; then
  mkdir -p "$S/root/audio-testing"
  cp -a "$AUDIO_DIR/." "$S/root/audio-testing/"
  for b in pcmtone tmix i2cprobe; do
    [ -f "$S/root/audio-testing/$b" ] && ln -sf "/root/audio-testing/$b" "$S/usr/local/bin/$b"
  done
fi

# --- AGDSP firmware into the booted rootfs /lib/firmware (see FW_DIR note) ---
if [ -d "$FW_DIR" ]; then
  mkdir -p "$S/lib/firmware"
  cp -a "$FW_DIR/." "$S/lib/firmware/"
fi

# --- build the ext4 image from the staged tree (fakeroot preserves ownership) ---
rm -f "$ROOTFS_IMG"
mke2fs -q -t ext4 -L rgrotate-root -d "$S" -F "$ROOTFS_IMG" "${ROOTFS_MB}M"
FAKE
echo "==> root fs built"

# ---------------------------------------------------------------------------
# 3. Assemble the whole-disk image: GPT + dd the raw uboot image and the two
#    filesystems into their partition offsets.
# ---------------------------------------------------------------------------
truncate -s "$((TOTAL_MB * MiB))" "$OUT_IMG"

# GPT, sector units. Named partitions so the SPL/tooling can find them by label:
#   p1 "uboot"         -> Linux reserved-bootloader GUID  (raw, no filesystem)
#   p2 "RGROTATE_BT"   -> EFI System / FAT (u-boot reads extlinux here)
#   p3 "rgrotate-root" -> Linux filesystem GUID
GUID_UBOOT="21686148-6449-6E6F-744E-656564454649"  # BIOS boot / raw bootloader
GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"     # EFI System Partition (FAT)
GUID_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"   # Linux filesystem
sfdisk "$OUT_IMG" >/dev/null <<EOF
label: gpt
unit: sectors
sector-size: 512
start=$((P1_START_MB * MiB / 512)), size=$((UBOOT_MB * MiB / 512)),  type=$GUID_UBOOT, name="uboot"
start=$((P2_START_MB * MiB / 512)), size=$((BOOT_MB * MiB / 512)),   type=$GUID_ESP,   name="RGROTATE_BT"
start=$((P3_START_MB * MiB / 512)), size=$((ROOTFS_MB * MiB / 512)), type=$GUID_LINUX, name="rgrotate-root"
EOF

dd if="$UBOOT_IMG"  of="$OUT_IMG" bs=1M seek="$P1_START_MB" conv=notrunc status=none
dd if="$BOOT_IMG"   of="$OUT_IMG" bs=1M seek="$P2_START_MB" conv=notrunc status=none
dd if="$ROOTFS_IMG" of="$OUT_IMG" bs=1M seek="$P3_START_MB" conv=notrunc status=none

echo
echo "Created: $OUT_IMG"
echo "Size:    $((TOTAL_MB * MiB)) bytes (${TOTAL_MB} MiB)"
echo "SHA256:  $(sha256sum "$OUT_IMG" | awk '{print $1}')"
echo
echo "Partition table:"
sfdisk -d "$OUT_IMG" 2>/dev/null | sed 's/^/  /'
echo
echo "Flash to an SD card with e.g.:"
echo "  sudo dd if=$OUT_IMG of=/dev/sdX bs=4M conv=fsync status=progress"
