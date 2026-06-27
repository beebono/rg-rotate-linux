# Linux on the Anbernic RG Rotate (Unisoc UMS512 / T618)

Mainline Linux on the Anbernic RG Rotate handheld. Board: `ums512_1h10`
(Unisoc T618 / UMS512, sharkl5pro), A/B partitions, originally Android 12.

**Mainline 6.16 boots a Debian 12 rootfs on eMMC with a working USB serial
console and a live panel.** For the current per-subsystem status and bring-up
detail, see **[DEVICE-BRINGUP.md](DEVICE-BRINGUP.md)**.

## Clone

This repo uses submodules (the kernel, U-Boot trees, busybox, and vendor
tooling each live in their own fork):

```bash
git clone --recurse-submodules <repo-url>
# or, after a plain clone:
git submodule update --init --recursive
```

## Repository layout

| Path | What |
|------|------|
| `src/linux-6-16-sprd/` | Linux 6.16 SPRD-flavored kernel fork (branch `ums512`) — **boots the device**, default target for the recipes below |
| `src/u-boot-sprd/` | Mainline-ish SPRD U-Boot (branch `rg-rotate`) — parked/experimental cleaner boot chain |
| `src/busybox/` | busybox source for the initramfs |
| `src/initramfs/` | initramfs overlay + reproducible build script (see [src/initramfs/README.md](src/initramfs/README.md)) |
| `src/rootfs-build/` | Debian rootfs image build scripts (see [src/rootfs-build/README.md](src/rootfs-build/README.md)) |
| `src/panel-generic-dsi/` | panel module implementation / bring-up workspace |
| `vendor/u-boot-ums512/` | vendor U-Boot BSP — extlinux experiment (see [docs/BOOT-CHAIN.md](docs/BOOT-CHAIN.md)) |
| `vendor/android-kernel-ums512/` | vendor Android BSP kernel — register-level reference |
| `vendor/spl-uboot-patch/` | AVB/unlock/secure-boot-bypass toolkit |
| `vendor/bootloader-unlock/` | Unisoc bootloader unlock tooling |
| `vendor/datasheets/` | SoC/PMIC datasheets |
| `tools/spd_dump/` | Spreadtrum FDL flashing tool (+ udev rule) — **primary flash path** |
| `tools/scripts/` | build/pack helpers (`build_vendor_*`, `pack_*`, `mkdtimg.py`) |
| `tools/mkbstub/`, `tools/devmemn/` | `mkbootimg` stub; on-target MMIO peek/poke |
| `device/` | stock dumps, extracted firmware, flashable images (gitignored — local) |
| `build/` | generated images and scratch outputs (gitignored) |

## Build

From the repo root, using `aarch64-linux-gnu-` and gcc 13:

```bash
# Kernel + DTB
make -C src/linux-6-16-sprd ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs

# initramfs (builds busybox from the submodule, assembles overlay, packs cpio.gz)
src/initramfs/build-initramfs.sh          # -> build/initramfs/initramfs.cpio.gz

# boot.img
PYTHONPATH=tools/mkbstub mkbootimg --header_version 4 \
  --kernel src/linux-6-16-sprd/arch/arm64/boot/Image \
  --ramdisk build/initramfs/initramfs.cpio.gz \
  --cmdline "console=tty0 ignore_loglevel rdinit=/init" \
  -o build/boot/boot_custom.img

# vendor_boot.img (carries the DTB)
PYTHONPATH=tools/mkbstub mkbootimg --header_version 4 \
  --vendor_boot build/boot/vendor_boot_custom.img \
  --dtb src/linux-6-16-sprd/arch/arm64/boot/dts/sprd/ums512-1h10.dtb \
  --vendor_ramdisk <empty-vendor-ramdisk> \
  --pagesize 4096 --base 0x0 --kernel_offset 0x8000 \
  --ramdisk_offset 0x5400000 --tags_offset 0x100 --dtb_offset 0x1f00000
```

For a quick repack of just the DTB into vendor_boot, use
`tools/scripts/build_vendor_boot_img.sh`.

Notes:
- USB serial needs `g_serial`, `u_serial`, and `f_acm` built in.
- USB `dr_mode` **must stay `"otg"`** in the board DTB: the sprd musb glue only
  registers the usb_role_switch in OTG mode, and the initramfs `init` drives that
  role switch (writes `device` to `/sys/class/usb_role/*/role`) to assert the
  gadget session + D+ — this board has no VBUS session edge. `dr_mode="peripheral"`
  removes the role switch and the gadget never enumerates (host sees `-71`).
- `clk_ignore_unused`/`regulator_ignore_unused` are **not** needed — eMMC/SD
  supplies are wired explicitly in the DTB. See [DEVICE-BRINGUP.md](DEVICE-BRINGUP.md).

## Flash and connect

Button note: there is no software volume control yet, so the **Home/Back combo
button** is the FDL/recovery key. The **actual Vol-Down** is a separate button,
used only in the force-off combo below.

Enter FDL: force the device off (hold **Vol-Down + Power**), then hold the
**Home/Back combo button** while plugging in USB. The host should enumerate
`1782:4d00`.

```bash
cd tools/spd_dump

./spd_dump --wait 300 keep_charge 1 \
  fdl ../../device/stock/fw/extracted/fdl1-dl.bin 0x5500 \
  fdl ../../device/stock/fw/extracted/fdl2-dl.bin 0x9EFFFE00 \
  exec \
  write_part boot_a ../../build/boot/boot_custom.img \
  poweroff
```

`exec` must come after the two `fdl` loads and before the `write_part`s; `poweroff`
is the final command. For DTB changes, rebuild and repack `vendor_boot_custom.img`,
then `write_part vendor_boot_a ...` (multiple `write_part`s can follow one `exec`).
`FDL2: incompatible partition` is benign. After flashing, force off fully
(spd_dump ... poweroff) and then power on — USB-plug boot works best so far, and
warm reset is unreliable for USB enumeration.

Connect to the console:

```bash
sudo modprobe cdc_acm
picocom -b 115200 /dev/ttyACM0
```

The kernel gadget enumerates as `0525:a4a7`. If you still see `1782:4d00`, that
is not the Linux console yet.

## Recovery

If the device becomes unreachable, force it off (**Vol-Down + Power**), then hold
the **Home/Back combo button** while plugging in USB to enter BROM/FDL, then
`write_part` the stock images from `device/stock/dump/`. The udev
rule at `tools/spd_dump/90-spd-dump.rules` allows `spd_dump` access without
`sudo` once installed.

## Documentation

- **[DEVICE-BRINGUP.md](DEVICE-BRINGUP.md)** — status, bring-up checklist, per-subsystem notes
- [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md) — DRM/DSI panel recipe and live-debug detail
- [docs/BOOT-CHAIN.md](docs/BOOT-CHAIN.md) — secure-boot bypass, vendor U-Boot extlinux porting, partition map
- [docs/WHAT-HAS-BEEN-TRIED.md](docs/WHAT-HAS-BEEN-TRIED.md) / [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md) — full chronology and dead ends
- [docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md](docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md) — captured known-good DSI register fingerprint
- [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md) — PMIC / fuel gauge / charger notes
