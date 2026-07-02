#!/usr/bin/env bash
#
# Rebuild the kernel DTB and repack vendor_boot (which carries the DTB) so DTS
# changes can be flashed with a single `write_part vendor_boot_a`.
#
# The vendor ramdisk and all header offsets are inherited from an existing
# vendor_boot image (TEMPLATE_IMG) so the repack is byte-faithful except for the
# DTB. Defaults target the in-tree ums512-rg-rotate board.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/src/linux-7-1-sprd}"
DTB="${DTB:-$KERNEL_DIR/arch/arm64/boot/dts/sprd/ums512-rg-rotate.dtb}"
DTB_SRC_REL="arch/arm64/boot/dts/sprd/ums512-rg-rotate.dtb"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

# Existing vendor_boot to inherit the vendor ramdisk + header from, and the
# output (overwritten in place by default so the flash recipe is unchanged).
TEMPLATE_IMG="${TEMPLATE_IMG:-$SCRIPT_DIR/vendor_boot_custom.img}"
OUTPUT_IMG="${1:-$SCRIPT_DIR/vendor_boot_custom.img}"

# Header geometry (matches the project's mkbootimg recipe / the stock layout).
PAGESIZE="${PAGESIZE:-4096}"
BASE="${BASE:-0x0}"
KERNEL_OFFSET="${KERNEL_OFFSET:-0x8000}"
RAMDISK_OFFSET="${RAMDISK_OFFSET:-0x5400000}"
TAGS_OFFSET="${TAGS_OFFSET:-0x100}"
DTB_OFFSET="${DTB_OFFSET:-0x1f00000}"

export PYTHONPATH="$REPO_ROOT/tools/mkbstub${PYTHONPATH:+:$PYTHONPATH}"

for cmd in make python3 mkbootimg unpack_bootimg; do
    if ! command -v "$cmd" >/dev/null 2>&1 \
        && ! python3 -c "import ${cmd}" >/dev/null 2>&1; then
        # mkbootimg/unpack_bootimg are provided as console scripts on PATH via
        # PYTHONPATH=tools/mkbstub; fall through and let the call fail loudly if
        # they are genuinely missing.
        :
    fi
done

if [[ ! -f "$TEMPLATE_IMG" ]]; then
    echo "Template vendor_boot not found: $TEMPLATE_IMG" >&2
    echo "Set TEMPLATE_IMG=... to an existing vendor_boot image." >&2
    exit 1
fi

echo "Building DTB ($DTB_SRC_REL)"
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" dtbs

if [[ ! -f "$DTB" ]]; then
    echo "Missing built DTB: $DTB" >&2
    exit 1
fi

# Pull the vendor ramdisk out of the template so we repack with the real one
# (an empty/placeholder ramdisk would still boot but we keep it faithful).
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
echo "Extracting vendor ramdisk from $(basename "$TEMPLATE_IMG")"
unpack_bootimg --boot_img "$TEMPLATE_IMG" --out "$WORK_DIR" >/dev/null
VENDOR_RAMDISK="$WORK_DIR/vendor_ramdisk00"
if [[ ! -f "$VENDOR_RAMDISK" ]]; then
    echo "Could not find vendor_ramdisk00 in template; aborting." >&2
    exit 1
fi

# Back up the output if we are overwriting it in place.
if [[ -f "$OUTPUT_IMG" ]]; then
    cp "$OUTPUT_IMG" "$OUTPUT_IMG.bak"
fi

echo "Repacking $(basename "$OUTPUT_IMG") with new DTB"
mkbootimg --header_version 4 \
    --vendor_boot "$OUTPUT_IMG" \
    --dtb "$DTB" \
    --vendor_ramdisk "$VENDOR_RAMDISK" \
    --pagesize "$PAGESIZE" --base "$BASE" --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" --tags_offset "$TAGS_OFFSET" \
    --dtb_offset "$DTB_OFFSET"

echo
echo "Repacked: $OUTPUT_IMG"
unpack_bootimg --boot_img "$OUTPUT_IMG" --out "$WORK_DIR/verify" 2>/dev/null \
    | grep -E 'header version|dtb size|vendor ramdisk total' || true

echo
echo "Flash with:"
echo "cd tools/spd_dump"
echo "./spd_dump --wait 300 keep_charge 1 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl1-dl.bin 0x5500 \\"
echo "  fdl ../../device/stock/fw/extracted/fdl2-dl.bin 0x9EFFFE00 \\"
echo "  exec \\"
echo "  write_part vendor_boot_a $(basename "$OUTPUT_IMG") \\"
echo "  poweroff"
