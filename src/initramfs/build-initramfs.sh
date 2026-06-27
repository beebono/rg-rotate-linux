#!/bin/bash
# Build the RG Rotate busybox initramfs reproducibly.
#
# Inputs (tracked in git):
#   busybox.config   - the busybox .config that produced the working binary
#   overlay/         - authored files copied verbatim over the busybox tree (init, etc.)
#
# Output:
#   build/initramfs/root/             - the assembled initramfs tree (scratch)
#   build/initramfs/initramfs.cpio.gz - the ramdisk consumed by mkbootimg
#
# Nothing generated is written under src/initramfs; the assembled tree lives in
# build/ (gitignored). Override CROSS_COMPILE / JOBS via the environment.
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
BUSYBOX_DIR="${BUSYBOX_DIR:-$REPO_ROOT/src/busybox}"
CONFIG="${CONFIG:-$PWD/busybox.config}"
OVERLAY="$PWD/overlay"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/initramfs}"
ROOT_DIR="$OUT_DIR/root"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

[ -f "$CONFIG" ] || { echo "ERROR: missing busybox config at $CONFIG" >&2; exit 1; }
[ -d "$BUSYBOX_DIR" ] || { echo "ERROR: busybox submodule not checked out at $BUSYBOX_DIR (run: git submodule update --init src/busybox)" >&2; exit 1; }

# --- build busybox from the submodule using the tracked config ---
cp "$CONFIG" "$BUSYBOX_DIR/.config"
make -C "$BUSYBOX_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" oldconfig
make -C "$BUSYBOX_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"

# --- assemble the initramfs tree ---
rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"
# busybox 'install' lays down bin/, sbin/, usr/ and the applet symlinks
make -C "$BUSYBOX_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CONFIG_PREFIX="$ROOT_DIR" install

# runtime mount points (init mounts proc/sys/devtmpfs onto these)
mkdir -p "$ROOT_DIR"/{dev,proc,sys,tmp,etc}
ln -sf bin/busybox "$ROOT_DIR/linuxrc"

# authored overlay (init and anything else) wins over busybox defaults
cp -a "$OVERLAY/." "$ROOT_DIR/"
chmod +x "$ROOT_DIR/init"

# --- pack ---
mkdir -p "$OUT_DIR"
( cd "$ROOT_DIR" && find . | cpio -H newc -o 2>/dev/null | gzip -9 ) > "$OUT_DIR/initramfs.cpio.gz"
echo "Built: $OUT_DIR/initramfs.cpio.gz"
ls -lh "$OUT_DIR/initramfs.cpio.gz"
