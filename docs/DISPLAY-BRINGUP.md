# Display / DRM bring-up

Goal: drive the `lcd_gt911_mipi_ab021` MIPI-DSI panel (720x720, 2-lane RGB888) with mainline `DRM_SPRD`. **Cold kernel-native init works** (2026-06-26): fbcon is visible and the device boots to a Debian login prompt on-screen, with `handoff_skip_first_cycle = false` — no U-Boot handoff dependency, on both USB-plug and power-button boot.

## What makes the panel display (the working recipe)

Cold kernel-native init lights the panel. Four things together produce a live panel; all committed on the `ums512` branch:

1. **Run sprd_dsi pre_enable before the panel's prepare.** `ctx->panel.prepare_prev_first = true` in `panel-generic-dsi.c` probe. The DRM bridge chain otherwise calls the panel's `prepare` (144 init DCS) *before* `sprd_dsi_bridge_pre_enable` has initialised the host, and sprd_dsi then resets the controller and wipes the init. Forcing sprd_dsi first gives: controller up + LP cmd mode, *then* panel init — the vendor U-Boot order.
2. **Arm the clock lane before the panel's init writes.** `sprd_dsi_bridge_pre_enable` sets `AUTO_CLKLANE_CTRL_EN` (for the NON_CONTINUOUS clock path) after enabling LP cmd mode, before `set_work_mode(DSI_MODE_CMD)`. Without it the clock lane can't engage and the first init command's FIFO never drains (`tx cmd fifo is not empty`, -110). This used to be set only in `sprd_dsi_bridge_enable`, which now runs after the panel writes.
3. **DSI-side DPI halt disabled.** `sprd_dsi_set_work_mode()` in `sprd_dsi.c` writes `DSI_MODE_CFG = 0` for video mode (not `DSI_VIDEO_HALT_EN`).
4. **DPU-side DPI halt disabled.** `sprd_dpu_init()` clears `BIT_DPU_DPI_HALT_EN` (does not set it).

Together (3)+(4) mean **both halt halves are off and the DPU free-runs** — this matches the only register fingerprint ever observed to light the panel (`DPI_CTRL=0x0`, `DSI_MODE_CFG=0x0`; full capture in [DISPLAY-KNOWN-GOOD-DSI-STATE.md](DISPLAY-KNOWN-GOOD-DSI-STATE.md)). Enabling either halt half parks the data lanes in stopstate (`PHY_STATUS 0x1f02`→`0x1f32`) and blanks the panel.

**`handoff_skip_first_cycle` is now `false`** (cold init). The legacy U-Boot-handoff path (flag `true`) still works as a fallback if a regression black-screens cold init; flipping it back inherits U-Boot's panel state instead of cold-initialising. **Reference binary:** `device/images/boot_custom.img.prehandoff` is build #67, the first image to ever display (handoff path). Its source is unrecoverable; keep the binary as a golden A/B reference.

## Open display work

- **Cold kernel-native init — SOLVED (2026-06-26).** Fixed by (1) `prepare_prev_first` bridge ordering and (2) arming the clock lane in `sprd_dsi_bridge_pre_enable` before the panel's init writes. The earlier "panel-side, U-Boot-only" conclusion was wrong in attribution: the controller *was* fine, but the panel init was being transmitted into an un-initialised / clock-idle controller and then reset. See [WHAT-HAS-BEEN-TRIED.md](WHAT-HAS-BEEN-TRIED.md) "SOLVED" section.
- **Unbind teardown bugs.** Unbinding `panel-generic-dsi` throws a `drm_bridge_put` refcount underflow and a `drm_vblank_init_release` WARN (non-fatal). Fix before relying on runtime rebind.
- **DCS short-read path is broken** (`-EIO` / "rx payload fifo empty"): the Synopsys controller stuffs short responses somewhere other than `GEN_PLD_DATA`. This blinds us to panel state during bring-up; fixing it would restore observability for the cold-init work. Not a blocker for the working handoff path.
- A DCS *read* turns the bus around (BTA) and parks the data lanes in stopstate, so avoid issuing reads on the hot display path.

## Source of panel data

The panel data did not come from mainline or the U-Boot BSP. It came from the stock dtbo overlay for this device's panel (`lcd_gt911_mipi_ab021`):

- `device/stock/dump/dtbo_a.img`
- `device/stock/dtbo_decompiled/dtbo_overlay_1.dts` — **authoritative source for panel bring-up on this board**

Note: `dtbo_decompiled/dtbo_overlay_0.dts` describes different panel candidates (`lcd_td4310_truly_mipi_fhd`, `lcd_ssd2092_truly_mipi_fhd`) shipped in the same DTBO for other SKUs. It is **not** applicable to this device and must not be used as a reference for GPIO assignments, polarities, lane counts, or init sequences.

Those describe:

- 2-lane rgb888
- phy bit clock `0x86c40` (551.488 Mbps)
- `sprd,initial-command` with 146 DCS commands
- reset sequence high50 / low50 / high120, **active-high** (stock declares the GPIO with flag 0x00 = `GPIO_ACTIVE_HIGH`; the sequence ends asserted-high, which only makes sense with active-high polarity)
- timing0 with dpi clk 38.4 MHz, hbp52, hfp46, hsync2, vbp25, vfp30, vsync2
- panel power via `ap_gpio 15` (AVDD) and `ap_gpio 138` (AVEE), both `GPIO_ACTIVE_HIGH`; reset on `ap_gpio 50`, `GPIO_ACTIVE_HIGH`
- backlight on SPRD PWM channel 2

The vendor register-level reference is `vendor/android-kernel-ums512/drivers/gpu/drm/sprd/`.

## Fixes already required to make the pipeline run

1. DPU hardware reset at init time
2. Re-applying size and timing after reset
3. Adding vendor QoS programming
4. Moving DPU RUN to the first configured flip
5. Disabling HALT on **both** the DPU side (`BIT_DPU_DPI_HALT_EN` cleared) and the DSI side (`DSI_MODE_CFG=0`). Vendor sets both; the free-running (halt-off) config is the only one that lights this panel. Enabling either half parks the data lanes in stopstate and blanks the screen — confirmed, do not re-enable.
6. Requesting and `prepare_enable`-ing the DPU matrix clock (`CLK_DISPC0`) and DPI pixel clock (`CLK_DISPC0_DPI`); mainline previously only fetched `CLK_DISPC_EB` (the APB gate) and relied on `clk_ignore_unused` for the rest
7. Powering up the DPHY analog block via two syscons that vendor BSP touches but mainline never wired: AP-AHB `0x40` bits 0,1 set, and AP-APB `0x35c` bit 3 cleared (with the 100us settle vendor's `dphy_power_domain` notes about "random wakeup failed")
8. Fixing panel sleep / display-on ordering and using continuous DSI clock
9. Sending `EXIT_SLEEP_MODE`/`SET_DISPLAY_ON` as 0-param DCS short writes, not 1-param with a bogus padding byte
10. Deferring `SET_DISPLAY_ON` from `panel.prepare` to a new `.enable` callback so it fires after the DSI bridge has switched to video mode

## Live debug notes

- A captured **known-good DSI host register fingerprint** (panel visibly showing fbcon via the U-Boot handoff path) lives in [DISPLAY-KNOWN-GOOD-DSI-STATE.md](DISPLAY-KNOWN-GOOD-DSI-STATE.md). Diff the kernel-native path against it; the failure mode reappears as the data-lane stopstate bits returning (`PHY_STATUS` `0x1f02` → `0x1f32`).
- `/usr/local/bin/devmemn` exists on the target for quick MMIO reads and writes. Usage is `devmemn <ADDR> [VAL]` — pass `VAL` **only** to write; address-only is a read.
- The boot log is the most reliable signal.
- `drmtest` and `modetest` are not useful while fbcon owns DRM master.
- `echo 4/0 > /sys/class/graphics/fb0/blank` wedges the console path and should be avoided.
- Do not poke `REG_DPU_CTRL` RUN directly via ad hoc MMIO writes.
- **`regulator_ignore_unused` is no longer required** (2026-06-26). It used to be load-bearing because eMMC/SD regulators were unclaimed; now `sdio3`/`sdio0` declare `vmmc`/`vqmmc` supplies in the DTB, so the flag (and `clk_ignore_unused`) were both dropped from the cmdline with eMMC + userland intact. If you ever lose storage after a DTB change, check those supply phandles before re-adding the flag.
- **DPU register offsets that matter for live probing** (mainline `sprd_dpu.c` definitions): `REG_DPU_CTRL=0x04`, `REG_DPU_INT_EN=0x1E0`, `REG_DPU_INT_STS=0x1E8`, `REG_DPU_INT_RAW=0x1EC`, `REG_DPI_CTRL=0x1F0`, `REG_DPI_H_TIMING=0x1F4`, `REG_DPI_V_TIMING=0x1F8`, `REG_DPU_STS0=0x360` (low 13 bits = current scanout line). The vendor `dpu_r4p0.h` uses these same offsets.
- `REG_DPU_CTRL`'s RUN/STOP/UPDATE bits are pulse-write — reading the register usually returns 0 even when the DPU is actively scanning. To prove the pipeline is alive, watch `REG_DPU_STS0`, not `REG_DPU_CTRL`.
- `REG_DPU_INT_STS` is cleared by the IRQ handler very quickly, so it often reads 0 even when interrupts are firing. `REG_DPU_INT_RAW` accumulates sources pre-mask but only certain bits stay sticky (`UPDATE_DONE` does; `VSYNC` doesn't always). Treat `REG_DPU_STS0` as the ground truth for "is DPU scanning?".
