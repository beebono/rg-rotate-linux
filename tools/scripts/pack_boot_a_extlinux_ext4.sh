#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_IMG="${1:-$SCRIPT_DIR/boot_a_extlinux_ext4.img}"
SIZE_TEMPLATE="${2:-$REPO_ROOT/device/stock/dump/boot_a.img}"

KERNEL_IMG="${KERNEL_IMG:-$REPO_ROOT/src/linux-7-1-sprd/arch/arm64/boot/Image}"
DTB_IMG="${DTB_IMG:-$REPO_ROOT/src/linux-7-1-sprd/arch/arm64/boot/dts/sprd/ums512-rg-rotate.dtb}"
INITRD_IMG="${INITRD_IMG:-$REPO_ROOT/build/initramfs/initramfs.cpio.gz}"
CMDLINE="${CMDLINE:-console=tty0 ignore_loglevel rdinit=/init}"

for f in "$KERNEL_IMG" "$DTB_IMG" "$INITRD_IMG" "$SIZE_TEMPLATE"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing required file: $f" >&2
        exit 1
    fi
done

for cmd in mkfs.ext4 truncate stat sha256sum find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required host tool: $cmd" >&2
        exit 1
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

size_bytes="$(stat -c '%s' "$SIZE_TEMPLATE")"
truncate -s "$size_bytes" "$OUT_IMG"

staging_dir="$tmpdir/staging"
mkdir -p "$staging_dir/extlinux"

cat >"$tmpdir/extlinux.conf" <<EOF
DEFAULT linux
TIMEOUT 0

LABEL linux
    KERNEL /Image
    INITRD /initramfs.cpio.gz
    FDT /ums512-rg-rotate.dtb
    APPEND $CMDLINE
EOF

cp "$KERNEL_IMG" "$staging_dir/Image"
cp "$DTB_IMG" "$staging_dir/ums512-rg-rotate.dtb"
cp "$INITRD_IMG" "$staging_dir/initramfs.cpio.gz"
cp "$tmpdir/extlinux.conf" "$staging_dir/extlinux/extlinux.conf"

# Vendor U-Boot (2015.07) ext4 can't parse 64bit group descriptors or
# metadata_csum; modern mkfs.ext4 enables both by default.
mkfs.ext4 -q -F -L BOOTA_EXT -O '^64bit,^metadata_csum,^orphan_file' \
    -d "$staging_dir" "$OUT_IMG"

echo "Created: $OUT_IMG"
echo "Size:    $size_bytes bytes"
echo "SHA256:  $(sha256sum "$OUT_IMG" | awk '{print $1}')"
echo
echo "Image contents:"
find "$staging_dir" -maxdepth 2 -printf '%P\n' | sed '/^$/d'
