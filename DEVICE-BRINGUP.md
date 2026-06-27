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
- [~] Power / PMIC / fuel gauge — SC2730 PMIC + regulators healthy; `sc2730_fgu` enabled & reporting battery V/SoC/temp (`/sys/class/power_supply/sc27xx-fgu`). Remaining: AW32257 I2C charger (no mainline driver) + charger status — see [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md)
- [ ] CPU freq / thermal
- [ ] Audio
- [ ] GPU
- [ ] Wi-Fi / Bluetooth
- [ ] Input
- [ ] SD card
- [ ] Sensors (only Hall-sensor expected, likely has accel/gyro though)
- [ ] USB host / OTG — gadget works; cold-boot enum `-71` deep-dive in [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md)
- [ ] UART clocks

Cross-reference `device/stock/dtb_stock.dts` whenever a node, supply, syscon, or
GPIO detail is unclear in mainline.

## Subsystem detail

- **Display / DRM** — [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md) (working recipe, panel data source, live-debug notes) and [docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md](docs/DISPLAY-KNOWN-GOOD-DSI-STATE.md) (register fingerprint).
- **Power / PMIC / charger** — [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md).
- **USB gadget / OTG** — [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md).
- **Boot chain / U-Boot / partitions** — [docs/BOOT-CHAIN.md](docs/BOOT-CHAIN.md).
- **Full chronology / dead ends** — [docs/WHAT-HAS-BEEN-TRIED.md](docs/WHAT-HAS-BEEN-TRIED.md).
