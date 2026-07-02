# Boot chain & U-Boot

## Secure-boot bypass (already flashed — do not re-flash)

The device already has a one-time secure-boot bypass chain flashed so that modified `boot`, `vendor_boot`, and `dtbo` are accepted without re-signing. Do not re-flash these unless something breaks:

- Patched SPL plus `device/images/uboot_ours_avbbypass.img`
- A neutralized `dtbo_a` image with the first four magic bytes zeroed so U-Boot skips dtbo merge
- Stock `vbmeta_a`, whose appended SPRD signature remains valid on the unlocked device

With that in place, iteration is just FDL `write_part`. The kernel DTB lives in `vendor_boot`, not `boot`. The unlock/bypass tooling lives in the `vendor/spl-uboot-patch` and `vendor/bootloader-unlock` submodules.

## Vendor U-Boot: panel-init + extlinux (primary strategy)

**Decision (2026-07-01):** rather than continuing to port pieces of a
mainline-ish U-Boot onto this hardware, the plan is to teach the **vendor BSP
U-Boot** — which already knows how to light the panel and drive this exact
board — to hand off via `extlinux`. The mainline-ish tree that used to be
parked at `src/u-boot-sprd` (branch `rg-rotate`, Otto Pflüger's codeberg fork)
showed no liveness on this hardware and has been **dropped from the repo**.
The vendor BSP fork, previously a submodule at `vendor/u-boot-ums512`, is now
the canonical U-Boot tree at **`src/u-boot/`** (same upstream,
`beebono/u-boot-ums512`, branch `main`).

`uboot_a` can be rebuilt and repacked locally. The current reproducible path is:

```bash
tools/scripts/build_vendor_uboot_img.sh
```

That rebuilds `src/u-boot` for `ums512_1h10`, packs `u-boot-dtb.bin` back into the stock `uboot_a` DHTB wrapper, and produces:

- `build/uboot/uboot_a_vendor_extlinux_booti.img`

The helper prints the matching `spd_dump write_part uboot_a ...` command for a single-slot test flash. See the [README build recipe](../README.md#build) for the equivalent manual `make`/pack steps.

### Vendor U-Boot → extlinux porting (status)

**2026-07-02: WORKING END-TO-END.** `extlinux_scan` boots the microSD's extlinux payload (config + initramfs + `Image` + DTB → `booti`), the kernel comes up, and the initramfs `switch_root`s into the eMMC rootfs. Scan order: microSD (`mmc 1:1`) first as a removable-media override, then eMMC `boot_a`/`boot_b` located by GPT name. Bugs found and fixed on the way (each one hardware-verified via the `uboot_log` readback below):

- **Env load addresses sat inside SoC carve-outs**: `fdt_addr_r`/`pxefile_addr_r` were inside tos-mem (0x94040000–0x9a000000), `ramdisk_addr_r` inside iq-mem (0x90000000+64M) — `boot_get_fdt` failed on the corrupted DTB. Now: kernel 0x80080000 (the vendor `KERNEL_ADR`; also booti's final placement so no relocation memmove), initrd 0x85000000, fdt 0x84e00000, pxefile 0x84d00000, `initrd_high`/`fdt_high=~0` (used in place).
- **`booti` relocated modern (`text_offset=0`) Images to DDR base 0x80000000** — on top of ddrbist/sysdumpinfo scratch and `CPU_RELEASE_ADDR`; patched to fall back to +0x80000.
- **`CONFIG_SUPPORT_RAW_INITRD` was off** — `boot_get_ramdisk` rejected the raw `initramfs.cpio.gz` ("Wrong Ramdisk Image Format").
- **`puts()` bypassed the SPRD log capture** (it only hooked `printf`), hiding every bootm/booti error; capture now lives in `puts()` so both are recorded.

- **fs/fat/fat.c `disk_read`**: vendor patch remapped a legitimate 0-block read (sub-sector files like `extlinux.conf`: `get_cluster` idx=0) into `-1` → deterministic "Error reading cluster". Guarded `nr_blocks == 0`.
- **drivers/mmc/sprd_sdhci_r11.c**: no dcache invalidate after SDMA reads — callers deterministically read back their own pre-read buffer content (observed as all-zero ext4 superblocks from `zalloc`'ed buffers while an aligned static buffer read of the same LBA returned the real data). Added post-read `invalidate_dcache_range`. This was the entire "eMMC ext4 won't mount" mystery; boot_a's ext4 content was always fine.
- **SD host registration**: the boot path only inits the eMMC; `board_sd_init()` (registers SDIO0 as mmc dev **1**) is only called by sysdump/SD-log paths. `extlinux_scan` now calls it (SD capped to 25 MHz default speed for bring-up; HS DLL delay in `sdio_cfg.c` is untuned for this board — restore speed later).
- **ext4 images must be built with `-O ^64bit,^metadata_csum,^orphan_file`** (2015-era ext4 driver); `pack_boot_a_extlinux_ext4.sh` updated.

Resolved unknowns: eMMC user area = U-Boot **mmc dev 0**; GPT partition numbers are 1-based with splloader outside the GPT (`boot_a`=42, `boot_b`=43, confirmed by on-device GPT dump); `extlinux_scan` now also locates `boot_a`/`boot_b` **by GPT name** and tries them first. prodnv (part 1) is FAT-formatted and mounts — expected scan noise.

Diagnostics without UART (the enabler for all of the above): every U-Boot `printf` is captured to a DRAM buffer (`CONFIG_SPRD_LOG`) and `extlinux_diag.c`/`cmd_pxe.c`/`loader_common.c` raw-write it to offset 0 of the 4 MB `uboot_log` partition at checkpoints (including right before the `booti` jump). Read back with `spd_dump ... r uboot_log`. The stock `write_log()` macros are DEBUG-gated no-ops and `write_uboot_last_log()` is skipped in DOWNLOAD boot-role — hence the direct `common_raw_write` calls.

Earlier in-tree groundwork:

- `include/configs/ums512_1h10.h` bootcmd changed from `cboot normal` to `run bootcmd_linux; cboot; cboot fastboot` (via `do_role`), with `bootcmd_linux=extlinux_scan`.
- `CONFIG_CMD_BOOTI` enabled and `cmd_pxe.c` `label_boot()` taught to try `booti` for raw arm64 `Image` (the extlinux payload from `tools/scripts/pack_boot_a_extlinux_fat32.sh` / `pack_boot_a_extlinux_ext4.sh` is `booti`-shaped, not `bootm`).
- `board/spreadtrum/ums512_1h10/extlinux_diag.c` adds `extlinux_scan`: `logo_display()` first (an `lcd_printf` is invisible until a DPU layer flip + backlight, which only `logo_display()` does), SD registration + read ladder, GPT-name partition lookup, probe loop with per-step `uboot_log` flushes.
- Env is `CONFIG_ENV_IS_NOWHERE` (not persistent) — the flow must be compiled in, not `setenv`/`saveenv`'d on device.

U-Boot panel init is still black (secondary while extlinux is the focus): panel attaches via the `sprd,lcd-no-id` fallback but every init DCS write stalls (`tx cmd fifo is not empty`) — the same clock-lane failure signature the kernel cold-init fix (linux `6cf23bd6bd3b`) addressed. `sprd,non-coninuous-clk-en = <1>` (vendor typo'd prop) in `lcd_rgrotate_mipi_720.dtsi` arms `auto_clklane_ctrl_en` at dsi-init time but did not clear it; `panel_init()` now re-arms it after LP-cmd enable (kernel-fix ordering) — untested. `logo_display` runs (backlight comes on, `dpu_wait_update_done` times out once).

Known-good standalone build expects `ARCH=arm` (board boots AArch64 Linux anyway):

```bash
make -C src/u-boot ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- O=out-test ums512_1h10_defconfig
make -C src/u-boot ARCH=arm DEVICE_TREE=ums512_1h10 CROSS_COMPILE=aarch64-linux-gnu- O=out-test -j$(nproc)
# pack out-test/u-boot-dtb.bin into the stock uboot_a DHTB wrapper:
python3 tools/scripts/pack_unisoc_uboot.py \
  device/stock/dump/uboot_a.img out-test/u-boot-dtb.bin \
  build/uboot/uboot_a_vendor_extlinux_booti.img
```

Open items: U-Boot panel init (above — kernel display works, so this only affects boot-time UI); SD speed restore (capped to 25 MHz default speed in `board_sd_init` because the fixed HS DLL delay in `sdio_cfg.c` is untuned for this board — kernel loads at ~2.7 MiB/s); eMMC `boot_a` extlinux payload as the SD-free daily path (ext4 reads fixed via an aligned bounce buffer in `fs/ext4/dev.c` — DMA reads into heap buffers return stale data on this platform — but the last flashed boot_a image predates the `mkfs -O ^64bit,^metadata_csum` fix and needs re-packing). Console visibility is solved for U-Boot by the `uboot_log` flow (no interactive console, but full boot logs after the fact).

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
