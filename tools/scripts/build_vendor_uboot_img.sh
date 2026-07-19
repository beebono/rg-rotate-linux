#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

UBOOT_DIR="${UBOOT_DIR:-$REPO_ROOT/src/u-boot}"
OUT_DIR="${OUT_DIR:-$UBOOT_DIR/out-test}"
DEFCONFIG="${DEFCONFIG:-ums512_rg_rotate_defconfig}"
DEVICE_TREE="${DEVICE_TREE:-ums512_rg_rotate}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

TEMPLATE_IMG="${TEMPLATE_IMG:-$REPO_ROOT/device/stock/fw/extracted/uboot_b.img}"
OUTPUT_IMG="${1:-$REPO_ROOT/build/boot/uboot_custom.img}"

for cmd in make python3 sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required host tool: $cmd" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$OUTPUT_IMG")"

echo "Building vendor U-Boot in $OUT_DIR"
make -C "$UBOOT_DIR" \
    ARCH=arm DEVICE_TREE="$DEVICE_TREE" \
    CROSS_COMPILE="$CROSS_COMPILE" O="$OUT_DIR" -j"$JOBS" \
    "$DEFCONFIG" u-boot-dtb.bin

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
echo "./spd_dump --wait 300 keep_charge 1 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl1-dl.bin 0x5500 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl2-dl.bin 0x9EFFFE00 \\"
echo "  exec \\"
echo "  write_part uboot_a $OUTPUT_IMG \\"
echo "  poweroff"
echo
echo "SHA256: $(sha256sum "$OUTPUT_IMG" | awk '{print $1}')"
