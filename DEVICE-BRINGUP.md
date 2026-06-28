# RG Rotate device bring-up status

Board: `ums512_1h10` (Unisoc T618 / UMS512, sharkl5pro). For build/flash/connect
recipes and repo layout see the [README](README.md).

## Status

**Mainline 6.16 boots a Debian 12 rootfs on eMMC with a working USB serial
console AND a live panel.**

- Kernel `6.16.0-sprd-ums512+` boots from `boot_a`; the busybox initramfs `/init`
  `switch_root`s into Debian 12 (bookworm) on `mmcblk3p74`.
- Interactive autologin root shell over USB-C at host `/dev/ttyACM0` (CDC-ACM
  gadget), no UART hardware required.
- eMMC enumerates; both watchdogs are fed by `hw-watchdog.service`; backlight
  stays on through boot.
- **The panel displays.** As of build #76 (2026-06-26) the device shows fbcon on
  the 720x720 panel and boots through to a Debian login prompt on-screen.

Current stage: userland hardware bring-up. The live serial console, on-disk
Debian, and on-screen console are the primary workflow.

**Display — cold kernel-native init now works (2026-06-26).** The panel lights
from cold with `handoff_skip_first_cycle = false`, no U-Boot handoff dependency,
on both USB-plug and power-button boot. The months-long wall was **not** the
DPI↔DSI pixel path, burst flags, or the DPU↔DSI halt handshake (all chased and
ruled out). Two fixes resolved it: (1) `ctx->panel.prepare_prev_first = true` in
`panel-generic-dsi.c` so `sprd_dsi_bridge_pre_enable` runs before the panel's
`prepare`; and (2) arming the clock lane (`AUTO_CLKLANE_CTRL_EN`) inside
`sprd_dsi_bridge_pre_enable` before those init writes. Both DPI halt halves stay
disabled (free-run). Full recipe in [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md);
chronology and dead ends in [docs/WHAT-HAS-BEEN-TRIED.md](docs/WHAT-HAS-BEEN-TRIED.md).

## Bring-up checklist

- [x] Storage / rootfs
- [x] Display / DRM — cold kernel-native init works (fbcon + Debian login on panel), no U-Boot handoff needed — see [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md)
- [x] Clocks/regulators cleanup — both `*_ignore_unused` cmdline flags dropped; eMMC/SD supplies wired in DTB
- [x] Power / PMIC / fuel gauge / charger — SC2730 PMIC + regulators healthy; `sc2730_fgu` reporting battery V/SoC/temp (`/sys/class/power_supply/sc27xx-fgu`); AW32257 charger now driven by mainline `bq2415x` (`/sys/class/power_supply/bq24158-0`, USB/online). Root cause of the long-dead i2c4 bus was a wrong AP-APB DT address (`apapb` identity `ranges;` vs offset child addrs → i2c4 at `0x00700000` DDR, not `0x70700000`); fixed in `ums512.dtsi`. See [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md)
- NOTE: that same `ap-apb` `ranges` fix should also resolve **UART0 hanging when enabled** (uart0/uart1/i2c0-3/spi0-3 were all mis-addressed the same way; only eMMC/sdio worked because they used absolute addresses).
- [x] CPU freq / thermal — **cpufreq working, thermal sensors live, throttling wired.**
  - *Sensors:* all 3 `sprd,ums512-thermal` controllers (`ap_thm0/1/2`) probe, 12 `thermal_zone*` report sane calibrated temps (CPU clusters/cores, GPU). DT (nodes + efuse cal cells + zones) was already complete in `ums512.dtsi`; efuse shadow at reserved-mem `nvmem@800` is populated so `sen_delta_cal` calibration works.
  - *cpufreq:* register-level `sprd,sharkl5pro-cpudvfs` engine ported (4.14 vendor → 6.16) and **working on-device**: `policy0` = cpu0-5 (A55, 614MHz–1.82GHz), `policy6` = cpu6-7 (A75, 1.23–2.002GHz), schedutil scaling. `CONFIG_ARM_SPRD_CPUFREQ_HW=y`. The in-tree `sprd-cpufreq-v2` SMCCC-SIP path was a dead end here (stock firmware returns NOT_SUPPORTED for `SPRD_SIP_SVC_DVFS_*`). See [docs/CPUFREQ-PORT-PLAN.md](docs/CPUFREQ-PORT-PLAN.md).
  - *Thermal throttling — DONE.* The cpufreq driver sets `CPUFREQ_IS_COOLING_DEV`, so the core registers a cooling device per policy (`cpufreq-cpu0`, `cpufreq-cpu6`). The per-cluster `cooling-maps` reference the policy-leader CPUs (`&CPU0`/`&CPU6` — one cooling dev per policy, shared cluster clock), so the 70 °C passive trips now cap cluster frequency; 110 °C critical trip remains the shutdown backstop. (`No trip points found for thermal id=0` is benign — the trip-less `gpu`/`gpuank2` monitor-only zones.)
- [x] GPU — **Mali-G52 (Bifrost MP2) live under mainline panfrost (built-in).** Added `gpu@60000000` to `ums512.dtsi` (compatible `sprd,ums512-mali`/`arm,mali-bifrost`, IRQ 60 ×3, `gpu_clk` core/mem/bus, `&pmu UMS512_POWER_DOMAIN_GPU_TOP`, reset, `vddgpu`, OPP 384–850 MHz), enabled in `ums512-1h10.dts`, plus a `sprd,ums512-mali` match in `panfrost_drv.c`; `CONFIG_DRM_PANFROST=y`. Validated on-device: `mali-g52 id 0x7402`, `shader_present=0x3`, `/dev/dri/renderD128`; devfreq enumerates all 5 OPPs (`simple_ondemand`, auto-ramps off the 26 MHz boot default to 384 MHz); a direct uAPI smoke test (GET_PARAM + CREATE_BO → nonzero GPU VA + mmap readback) passes, confirming the GEM/MMU datapath. **Key fix:** a latent bug in `drivers/clk/sprd/ums512-clk.c` — `ums512_clk_probe` used `platform_get_drvdata()` (a `sprd_clk_drvdata *`) directly as the reset `regmap`, so the GPU's reset-deassert (the first ums512 node to request a reset) panicked with PC=`0x0` in `sprd_reset_deassert`; fixed to `data->regmap` (matches `ums9230-clk.c`) — candidate for upstreaming. Still untested: actual shader execution via `SUBMIT` (needs mesa/panfrost userspace, not yet installed — no network on device).
- [ ] SD card
- [ ] Wi-Fi / Bluetooth
- [ ] Audio
- [ ] Input
- [ ] Sensors (only Hall-sensor expected, likely has accel/gyro though)
- [ ] USB host / OTG — gadget works; cold-boot enum `-71` deep-dive in [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md)
- [ ] UART clocks
- [ ] DDR devfreq / DDR-DVFS — *could be done, but will take some time.* No sprd devfreq driver in mainline (devfreq core/governors enabled, but no Unisoc driver); no DDR-DVFS DT nodes. Vendor has a large proprietary stack (`drivers/devfreq/sprd/` ddr-dvfs core + `sprd_governor_vote`, `apsys/` DPU/GSP/VSP DVFS, `sprd-top-dvfs`) coupled to `topdvfsctrl@322a0000`/`dmc-mpu` + SIPC to a remote DVFS coprocessor — a multi-week port. DDR free-runs at the firmware-set frequency (stable). Right-shaped path if ever wanted: a thin SMCCC-SIP devfreq driver (like `sprd-cpufreq-v2`), but none exists in-tree yet

Cross-reference `device/stock/dtb_stock.dts` whenever a node, supply, syscon, or
GPIO detail is unclear in mainline.

## Subsystem detail

- **Display / DRM** — [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md) (working recipe, panel data source, live-debug notes) and [docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md](docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md) (register fingerprint).
- **Power / PMIC / charger** — [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md).
- **USB gadget / OTG** — [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md).
- **Boot chain / U-Boot / partitions** — [docs/BOOT-CHAIN.md](docs/BOOT-CHAIN.md).
- **Full chronology / dead ends** — [docs/WHAT-HAS-BEEN-TRIED.md](docs/WHAT-HAS-BEEN-TRIED.md).
