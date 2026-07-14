# Linux on the Anbernic RG Rotate (Unisoc UMS512 / T618)

Mainline Linux on the Anbernic RG Rotate handheld. Board: `ums512_1h10`
(Unisoc T618 / UMS512, sharkl5pro), A/B partitions, originally Android 12.

**Mainline 7.1 boots a Debian 13 (trixie) rootfs with a live panel, USB
dual-role OTG (device console + host), and working Wi-Fi/Bluetooth.** Day-to-day
development boots from a **microSD card** via U-Boot's `extlinux` scan (fast
to reflash, doesn't touch the eMMC); eMMC (`boot_a` + `mmcblk3p74` userdata)
remains the on-device/"installed" flow and is what recovery falls back to. For
the current per-subsystem status and bring-up detail, see
**[DEVICE-BRINGUP.md](DEVICE-BRINGUP.md)**.

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
| `src/linux-7-1-sprd/` | Linux 7.1 SPRD-flavored kernel fork (branch `rg-rotate`, off Otto Pflüger's codeberg `ums9230-mainline` line) — **boots the device**, default target for the recipes below. Board is `ums512-rg-rotate`. |
| `src/u-boot/` | Vendor U-Boot BSP fork (`ums512_1h10` board target) — lights the panel, then hands off to the kernel via an `extlinux.conf` scan (checks microSD `mmc 1:1` before the eMMC `boot_a`/`boot_b` slots); the canonical U-Boot tree |
| `src/busybox/` | busybox source for the initramfs |
| `src/initramfs/` | initramfs overlay + reproducible build script (see [src/initramfs/README.md](src/initramfs/README.md)) |
| `src/rootfs-build/` | Debian rootfs image build scripts (see [src/rootfs-build/README.md](src/rootfs-build/README.md)) |
| `src/panel-generic-dsi/` | panel module implementation / bring-up workspace |
| `vendor/android-kernel-ums512/` | vendor Android BSP kernel — register-level reference |
| `vendor/spl-uboot-patch/` | AVB/unlock/secure-boot-bypass toolkit |
| `vendor/bootloader-unlock/` | Unisoc bootloader unlock tooling |
| `vendor/datasheets/` | SoC/PMIC datasheets |
| `tools/spd_dump/` | Spreadtrum FDL flashing tool (+ udev rule) — **primary flash path** |
| `tools/scripts/` | build/pack helpers (`build_vendor_*`, `pack_*`, `mkdtimg.py`) and `build_sdcard_debian.sh` — builds the microSD dev-boot image (unprivileged, no loop devices/root) |
| `tools/mkbstub/`, `tools/devmemn/` | `mkbootimg` stub; on-target MMIO peek/poke |
| `device/` | stock dumps, extracted firmware, flashable images (gitignored — local) |
| `build/` | generated images and scratch outputs (gitignored) |

The earlier Linux 6.16 fork (branch `ums512`, board `ums512-1h10`) has been
retired from this superproject now that 7.1 has full feature parity — it still
exists on GitHub (`beebono/linux-6-16-sprd`) for reference if ever needed.

## Build

From the repo root, using `aarch64-linux-gnu-` and gcc 13:

```bash
# Kernel + DTB
make -C src/linux-7-1-sprd ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs

# initramfs (builds busybox from the submodule, assembles overlay, packs cpio.gz)
src/initramfs/build-initramfs.sh          # -> build/initramfs/initramfs.cpio.gz

# boot.img
PYTHONPATH=tools/mkbstub mkbootimg --header_version 4 \
  --kernel src/linux-7-1-sprd/arch/arm64/boot/Image \
  --ramdisk build/initramfs/initramfs.cpio.gz \
  --cmdline "console=tty0 ignore_loglevel rdinit=/init" \
  -o build/boot/boot_custom.img

# vendor_boot.img (carries the DTB). The vendor ramdisk is an unused
# placeholder (the real initramfs ships in boot.img above); pull the
# existing tiny one out of any prior vendor_boot build rather than
# constructing one from scratch:
PYTHONPATH=tools/mkbstub unpack_bootimg \
  --boot_img build/boot/vendor_boot_custom.img --out /tmp/vb_unpack
PYTHONPATH=tools/mkbstub mkbootimg --header_version 4 \
  --vendor_boot build/boot/vendor_boot_custom.img \
  --dtb src/linux-7-1-sprd/arch/arm64/boot/dts/sprd/ums512-rg-rotate.dtb \
  --vendor_ramdisk /tmp/vb_unpack/vendor_ramdisk00 \
  --pagesize 4096 --base 0x0 --kernel_offset 0x8000 \
  --ramdisk_offset 0x5400000 --tags_offset 0x100 --dtb_offset 0x1f00000
```

For a quick repack of just the DTB into vendor_boot, use
`tools/scripts/build_vendor_boot_img.sh`.

```bash
# Vendor U-Boot (src/u-boot, ums512_1h10 board target) — panel-init + extlinux work
make -C src/u-boot \
  O="$PWD/build/out/u-boot-vendor" \
  ARCH=arm \
  CROSS_COMPILE=aarch64-linux-gnu- \
  ums512_1h10_defconfig \
&& make -C src/u-boot \
  O="$PWD/build/out/u-boot-vendor" \
  ARCH=arm \
  CROSS_COMPILE=aarch64-linux-gnu- \
  -j"$(nproc)" \
&& python3 tools/scripts/pack_unisoc_uboot.py \
  device/stock/dump/uboot_a.img \
  build/out/u-boot-vendor/u-boot-dtb.bin \
  build/uboot/uboot_a_vendor_ums512_1h10.img
```

`tools/scripts/build_vendor_uboot_img.sh` wraps the same three steps and prints
the matching `spd_dump write_part uboot_a ...` command.

### microSD dev-boot image (faster iteration loop)

```bash
tools/scripts/build_sdcard_debian.sh   # -> rg-rotate-sdcard.img
```

Builds a full FAT32-boot + ext4-rootfs microSD image in one shot (kernel,
DTB, initramfs, `extlinux.conf`, and the Debian rootfs tar). `dd` it to a
card and boot — U-Boot's `extlinux_diag.c` scan checks `mmc 1:1` (the SD)
before the eMMC slots, so no reflashing eMMC is needed to test kernel/DTB
changes. The initramfs honors `root=` from the extlinux cmdline
(`/dev/mmcblk0p2` on SD vs the eMMC default below).

Notes:
- USB is dual-role OTG, switched automatically by the sc2730 PMIC's Type-C
  port manager (CC detection) — plugging into a host selects device (the
  `g_serial`/CDC-ACM console enumerates), plugging in a device selects host.
  Nothing in userspace or the initramfs forces the role anymore. See
  [docs/USB-OTG-HOST-CLEANUP.md](docs/USB-OTG-HOST-CLEANUP.md).
- USB `dr_mode` **must stay `"otg"`** in the board DTB: the sprd musb glue only
  registers the usb_role_switch in OTG mode — this board has no VBUS session
  edge otherwise. `dr_mode="peripheral"` removes the role switch and the
  gadget never enumerates (host sees `-71`).
- `clk_ignore_unused`/`regulator_ignore_unused` are **not** needed — eMMC/SD
  supplies are wired explicitly in the DTB. See [DEVICE-BRINGUP.md](DEVICE-BRINGUP.md).

## Flash and connect

For day-to-day kernel/DTB iteration, prefer the [microSD dev-boot
image](#microsd-dev-boot-image-faster-iteration-loop) — it needs no `spd_dump`
flashing at all, just `dd` the image to a card. The `spd_dump`/FDL flow below
is for flashing `boot_a`/`vendor_boot_a`/U-Boot itself on the eMMC (the
installed/on-device flow) or for recovery.

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

If ModemManager runs on your host, it treats the gadget as a candidate modem
and probes it with AT commands, which land as garbage on the target's login
shell. Install `tools/spd_dump/40-rgrotate-console-mm-ignore.rules` into
`/etc/udev/rules.d/` and `udevadm control --reload-rules && udevadm trigger`
to stop it.

## Recovery

If the device becomes unreachable, force it off (**Vol-Down + Power**), then hold
the **Home/Back combo button** while plugging in USB to enter BROM/FDL, then
`write_part` the stock images from `device/stock/dump/`. The udev
rule at `tools/spd_dump/90-spd-dump.rules` allows `spd_dump` access without
`sudo` once installed.

## Documentation

- **[DEVICE-BRINGUP.md](DEVICE-BRINGUP.md)** — status, bring-up checklist, per-subsystem notes
- [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md) — DRM/DSI panel recipe and live-debug detail
- [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md) — PMIC / fuel gauge / charger notes
