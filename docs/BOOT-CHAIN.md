# Boot chain & U-Boot

## Secure-boot bypass (already flashed — do not re-flash)

The device already has a one-time secure-boot bypass chain flashed so that modified `boot`, `vendor_boot`, and `dtbo` are accepted without re-signing. Do not re-flash these unless something breaks:

- Patched SPL plus `device/images/uboot_ours_avbbypass.img`
- A neutralized `dtbo_a` image with the first four magic bytes zeroed so U-Boot skips dtbo merge
- Stock `vbmeta_a`, whose appended SPRD signature remains valid on the unlocked device

With that in place, iteration is just FDL `write_part`. The kernel DTB lives in `vendor_boot`, not `boot`. The unlock/bypass tooling lives in the `vendor/spl-uboot-patch` and `vendor/bootloader-unlock` submodules.

## Vendor-BSP extlinux experiment

For the vendor-BSP extlinux experiment, `uboot_a` can also be rebuilt and repacked locally. The current reproducible path is:

```bash
tools/scripts/build_vendor_uboot_img.sh
```

That rebuilds `vendor/u-boot-ums512` for `ums512_1h10`, packs `u-boot-dtb.bin` back into the stock `uboot_a` DHTB wrapper, and produces:

- `build/uboot/uboot_a_vendor_extlinux_booti.img`

The helper prints the matching `spd_dump write_part uboot_a ...` command for a single-slot test flash.

### Vendor U-Boot → extlinux porting (status)

`vendor/u-boot-ums512` is the right hardware base (real `ums512_1h10` board target, eMMC/GPT/FAT/ext4/`sysboot`, SC2730 PMIC, Spreadtrum boot-mode handling) but is **not** a drop-in extlinux binary. It has no modern bootstd/`bootflow` framework, so the path is the older `sysboot` + `extlinux.conf`. In-tree progress:

- `include/configs/ums512_1h10.h` bootcmd changed from `cboot normal` toward a board-local `extlinux_scan` (`bootcmd_linux`) that probes a few `mmc dev:part` combinations. `boot_a`=`42`, `boot_b`=`43` are the known partition numbers; the U-Boot `mmc` *device* index for the eMMC user area is still unconfirmed on HW.
- `CONFIG_CMD_BOOTI` enabled and `cmd_pxe.c` `label_boot()` taught to try `booti` for raw arm64 `Image` (the extlinux payload from `tools/scripts/pack_boot_a_extlinux.sh` is `booti`-shaped, not `bootm`).
- `board/spreadtrum/ums512_1h10/extlinux_diag.c` adds `extlinux_scan`, mirroring probe progress to UART and `lcd_printf()`.
- Env is `CONFIG_ENV_IS_NOWHERE` (not persistent) — the flow must be compiled in, not `setenv`/`saveenv`'d on device.

Known-good standalone build expects `ARCH=arm` (board boots AArch64 Linux anyway):

```bash
make -C vendor/u-boot-ums512 ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- O=out-test ums512_1h10_defconfig
make -C vendor/u-boot-ums512 ARCH=arm DEVICE_TREE=ums512_1h10 CROSS_COMPILE=aarch64-linux-gnu- O=out-test -j$(nproc)
# pack out-test/u-boot-dtb.bin into the stock uboot_a DHTB wrapper:
python3 tools/scripts/pack_unisoc_uboot.py \
  device/stock/dump/uboot_a.img out-test/u-boot-dtb.bin \
  build/uboot/uboot_a_vendor_extlinux_booti.img
```

Open gating items, all hardware-validated: the correct `mmc` device index; DT-source choice for an extlinux boot (likely bake panel/board wiring into the Linux DTB and skip vendor DTBO); and console visibility (USB ACM in Linux does not imply an interactive U-Boot console — no UART pad exists, see [WHAT-HAS-BEEN-TRIED.md](WHAT-HAS-BEEN-TRIED.md)). The mainline-ish tree at `src/u-boot-sprd` (branch `rg-rotate`) is the parked fallback — it shows **no** liveness on this hardware and does not init the panel.

## Partition reference

Backups and the partition map live under `device/stock/dump/`.

| Partition | Purpose | Notes |
|-----------|---------|-------|
| `boot_a/b` | Kernel + initramfs | Custom build in slot A |
| `vendor_boot_a/b` | Vendor ramdisk + DTB | DTS changes go here |
| `dtbo_a/b` | DT overlay | `dtbo_a` is neutralized so overlay merge is skipped |
| `vbmeta_a/b` | AVB metadata | Keep stock |
| `uboot_a/b` | U-Boot | `device/images/uboot_ours_avbbypass.img` flashed |
| `sml/trustos/teecfg` | Secure monitor / TEE | Do not touch |
| `init_boot_a` | Former scratch partition | `/dev/mmcblk3p46` |
