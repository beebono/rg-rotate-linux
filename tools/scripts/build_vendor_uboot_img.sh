#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

UBOOT_DIR="${UBOOT_DIR:-$REPO_ROOT/vendor/u-boot-ums512}"
OUT_DIR="${OUT_DIR:-$UBOOT_DIR/out-test}"
DEFCONFIG="${DEFCONFIG:-ums512_1h10_defconfig}"
DEVICE_TREE="${DEVICE_TREE:-ums512_1h10}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

TEMPLATE_IMG="${TEMPLATE_IMG:-$REPO_ROOT/device/stock/dump/uboot_a.img}"
OUTPUT_IMG="${1:-$REPO_ROOT/build/uboot/uboot_a_vendor_extlinux_booti.img}"

for cmd in make python3 sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required host tool: $cmd" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$OUTPUT_IMG")"

echo "Building vendor U-Boot in $OUT_DIR"
make -C "$UBOOT_DIR" \
    ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" O="$OUT_DIR" \
    "$DEFCONFIG"

make -C "$UBOOT_DIR" \
    ARCH=arm DEVICE_TREE="$DEVICE_TREE" \
    CROSS_COMPILE="$CROSS_COMPILE" O="$OUT_DIR" -j"$JOBS"

PAYLOAD="$OUT_DIR/u-boot-dtb.bin"
if [[ ! -f "$PAYLOAD" ]]; then
    echo "Missing built payload: $PAYLOAD" >&2
    exit 1
fi

echo "Packing $PAYLOAD into stock U-Boot wrapper"
python3 "$SCRIPT_DIR/pack_unisoc_uboot.py" \
    "$TEMPLATE_IMG" \
    "$PAYLOAD" \
    "$OUTPUT_IMG"

echo
echo "Flash with:"
echo "cd tools/spd_dump"
echo "yes yes | ./spd_dump --wait 300 keep_charge 1 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl1-dl.bin 0x5500 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl2-dl.bin 0x9EFFFE00 \\"
echo "  write_part uboot_a $OUTPUT_IMG"
echo
echo "SHA256: $(sha256sum "$OUTPUT_IMG" | awk '{print $1}')"
