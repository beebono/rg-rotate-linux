#!/usr/bin/env bash
#
# Build the ARM Mali kbase kernel module (src/mali-kbase, branch bifrost_port)
# out-of-tree against the up-ported src/linux-7-1-sprd kernel, for the UMS512 /
# T618 Mali-G52 (Bifrost, Job Manager).  Replaces the vendor gondul/midgard
# kbase and the mainline panfrost module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/src/linux-7-1-sprd}"
MODULE_DIR="${MODULE_DIR:-$REPO_ROOT/src/mali-kbase/product/kernel/drivers/gpu/arm/midgard}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${ARCH:-arm64}"
JOBS="${JOBS:-$(nproc)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build}"

# ---- Mali config --------------------------------------------------------------

MALI_ARGS=(
    "CONFIG_MALI_MIDGARD=m"
    "CONFIG_MALI_PLATFORM_NAME=devicetree"
    "CONFIG_MALI_CSF_SUPPORT=n"
    "CONFIG_MALI_EXPERT=n"
    "CONFIG_MALI_REAL_HW=y"
    "CONFIG_MALI_DEVFREQ=y"
    "CONFIG_MALI_GATOR_SUPPORT=y"
    "CONFIG_LARGE_PAGE_SUPPORT=y"
)

usage() { sed -n '2,20p' "$0"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

# ---- Preflight ----------------------------------------------------------------
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    echo "Cross toolchain not found: ${CROSS_COMPILE}gcc" >&2
    echo "Install gcc-aarch64-linux-gnu or set CROSS_COMPILE=..." >&2
    exit 1
fi
if [[ ! -d "$MODULE_DIR" ]]; then
    echo "kbase module dir not found: $MODULE_DIR" >&2
    echo "Is the src/mali-kbase submodule checked out?" >&2
    exit 1
fi
if [[ ! -f "$KERNEL_DIR/.config" || ! -f "$KERNEL_DIR/Module.symvers" ]]; then
    echo "Kernel at $KERNEL_DIR is not configured/built." >&2
    echo "Build it first, e.g.:" >&2
    echo "  make -C $KERNEL_DIR ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE ums512_defconfig" >&2
    echo "  make -C $KERNEL_DIR ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS Image modules" >&2
    exit 1
fi

# ---- Clean (optional) ---------------------------------------------------------
if [[ "${1:-}" == "clean" ]]; then
    echo ">> make clean ($MODULE_DIR)"
    make -C "$MODULE_DIR" KDIR="$KERNEL_DIR" ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" "${MALI_ARGS[@]}" clean
    exit 0
fi

# ---- Build --------------------------------------------------------------------
echo ">> Building mali_kbase"
echo "   KERNEL_DIR = $KERNEL_DIR"
echo "   MODULE_DIR = $MODULE_DIR"
echo "   $(cd "$REPO_ROOT/src/mali-kbase" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true) @ \
$(cd "$REPO_ROOT/src/mali-kbase" && git rev-parse --short HEAD 2>/dev/null || true)"

make -C "$MODULE_DIR" \
    KDIR="$KERNEL_DIR" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$JOBS" \
    "${MALI_ARGS[@]}" \
    all

# ---- Collect ------------------------------------------------------------------
KO="$(find "$MODULE_DIR" -name 'mali_kbase.ko' -print -quit)"
if [[ -z "$KO" ]]; then
    echo "Build finished but mali_kbase.ko was not found under $MODULE_DIR" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
cp "$KO" "$OUT_DIR/mali_kbase.ko"
echo
echo ">> Built: $OUT_DIR/mali_kbase.ko"
"${CROSS_COMPILE}objdump" -h "$KO" >/dev/null 2>&1 || true
if command -v modinfo >/dev/null 2>&1; then
    echo "-- modinfo (vermagic / deps) --"
    modinfo "$OUT_DIR/mali_kbase.ko" 2>/dev/null | grep -E '^(vermagic|depends|name):' || true
fi
