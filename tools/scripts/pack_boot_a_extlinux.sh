#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_IMG="${1:-$SCRIPT_DIR/boot_a_extlinux.img}"
SIZE_TEMPLATE="${2:-$REPO_ROOT/device/stock/dump/boot_a.img}"

KERNEL_IMG="${KERNEL_IMG:-$REPO_ROOT/src/linux-6-16-sprd/arch/arm64/boot/Image}"
DTB_IMG="${DTB_IMG:-$REPO_ROOT/src/linux-6-16-sprd/arch/arm64/boot/dts/sprd/ums512-1h10.dtb}"
INITRD_IMG="${INITRD_IMG:-$REPO_ROOT/build/initramfs/initramfs.cpio.gz}"
# Console routing for bring-up visibility:
#  - earlycon=sprd_serial,<uart1 base>  : earliest output, HARDWARE UART ONLY
#    (cannot reach USB; only visible if the uart1 TX pad at 0x70100000 is tapped)
#  - console=ttyS1                      : full kernel console on the same UART pad
#  - console=ttyGS0                     : kernel console over the USB gadget (the
#    USB-visible channel); needs the gadget up, so it flushes once enumerated
#  - g_serial.use_acm=1                 : present the gadget as CDC-ACM so the host
#    binds cdc_acm -> reliable /dev/ttyACM0 instead of the flaky generic ttyUSB0
# ttyGS0 is listed last so /dev/console (hence init stdout) lands on USB.
CMDLINE="${CMDLINE:-earlycon=sprd_serial,0x70100000 console=ttyS1,115200n8 console=tty0 console=ttyGS0,115200 g_serial.use_acm=1 ignore_loglevel regulator_ignore_unused clk_ignore_unused rdinit=/init}"

for f in "$KERNEL_IMG" "$DTB_IMG" "$INITRD_IMG" "$SIZE_TEMPLATE"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing required file: $f" >&2
        exit 1
    fi
done

for cmd in mkfs.vfat mmd mcopy mdir truncate stat sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required host tool: $cmd" >&2
        exit 1
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

size_bytes="$(stat -c '%s' "$SIZE_TEMPLATE")"
truncate -s "$size_bytes" "$OUT_IMG"
mkfs.vfat -F 32 -n BOOTA_EXT "$OUT_IMG" >/dev/null

cat >"$tmpdir/extlinux.conf" <<EOF
DEFAULT linux
TIMEOUT 10

LABEL linux
    KERNEL /Image
    INITRD /initramfs.cpio.gz
    FDT /ums512-1h10.dtb
    APPEND $CMDLINE
EOF

mmd -i "$OUT_IMG" ::/extlinux
mcopy -i "$OUT_IMG" "$KERNEL_IMG" ::/Image
mcopy -i "$OUT_IMG" "$DTB_IMG" ::/ums512-1h10.dtb
mcopy -i "$OUT_IMG" "$INITRD_IMG" ::/initramfs.cpio.gz
mcopy -i "$OUT_IMG" "$tmpdir/extlinux.conf" ::/extlinux/extlinux.conf

echo "Created: $OUT_IMG"
echo "Size:    $size_bytes bytes"
echo "SHA256:  $(sha256sum "$OUT_IMG" | awk '{print $1}')"
echo
echo "Image contents:"
mdir -i "$OUT_IMG" ::/
echo
mdir -i "$OUT_IMG" ::/extlinux
