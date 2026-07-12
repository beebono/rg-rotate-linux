# RG Rotate device bring-up status

Board: `ums512_1h10` (Unisoc T618 / UMS512, sharkl5pro). For build/flash/connect
recipes and repo layout see the [README](README.md).

## Status

**Mainline 7.1 boots a Debian 13 rootfs on eMMC with a working USB serial
console AND a live panel.**

- Kernel `7.1.0-sprd-ums512+` boots from `boot_a`; the busybox initramfs `/init`
  `switch_root`s into Debian 13 (trixie) on `mmcblk3p74`.
- Interactive autologin root shell over USB-C at host `/dev/ttyACM0` (CDC-ACM
  gadget), no UART hardware required.
- eMMC enumerates; both watchdogs are fed by `hw-watchdog.service`; backlight
  stays on through boot.
- **The panel displays.** As of build #76 (2026-06-26) the device shows fbcon on
  the 720x720 panel and boots through to a Debian login prompt on-screen.

Current stage: userland hardware bring-up. The live serial console, on-disk
Debian, and on-screen console are the primary workflow.

## Bring-up checklist

- [x] Storage / rootfs
- [x] Display / DRM — cold kernel-native init works (fbcon + Debian login on panel), no U-Boot handoff needed — see [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md)
- [x] Clocks/regulators cleanup — both `*_ignore_unused` cmdline flags dropped; eMMC/SD supplies wired in DTB
- [x] Power / PMIC / fuel gauge / charger — SC2730 PMIC + regulators healthy; `sc2730_fgu` reporting battery V/SoC/temp (`/sys/class/power_supply/sc27xx-fgu`); AW32257 charger now driven by mainline `bq2415x` (`/sys/class/power_supply/bq24158-0`, USB/online). Root cause of the long-dead i2c4 bus was a wrong AP-APB DT address (`apapb` identity `ranges;` vs offset child addrs → i2c4 at `0x00700000` DDR, not `0x70700000`); fixed in `ums512.dtsi`. See [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md)
- NOTE: that same `ap-apb` `ranges` fix should also resolve **UART0 hanging when enabled** (uart0/uart1/i2c0-3/spi0-3 were all mis-addressed the same way; only eMMC/sdio worked because they used absolute addresses).
- [x] CPU freq / thermal — **cpufreq working, thermal sensors live, throttling wired.**
  - *Sensors:* all 3 `sprd,ums512-thermal` controllers (`ap_thm0/1/2`) probe, 12 `thermal_zone*` report sane calibrated temps (CPU clusters/cores, GPU). DT (nodes + efuse cal cells + zones) was already complete in `ums512.dtsi`; efuse shadow at reserved-mem `nvmem@800` is populated so `sen_delta_cal` calibration works.
  - *cpufreq:* register-level `sprd,sharkl5pro-cpudvfs` engine ported (4.14 vendor → 6.16) and **working on-device**: `policy0` = cpu0-5 (A55, 614MHz–1.82GHz), `policy6` = cpu6-7 (A75, 1.23–2.002GHz), schedutil scaling. `CONFIG_ARM_SPRD_CPUFREQ_HW=y`. The in-tree `sprd-cpufreq-v2` SMCCC-SIP path was a dead end here (stock firmware returns NOT_SUPPORTED for `SPRD_SIP_SVC_DVFS_*`).
  - *Thermal throttling — DONE.* The cpufreq driver sets `CPUFREQ_IS_COOLING_DEV`, so the core registers a cooling device per policy (`cpufreq-cpu0`, `cpufreq-cpu6`). The per-cluster `cooling-maps` reference the policy-leader CPUs (`&CPU0`/`&CPU6` — one cooling dev per policy, shared cluster clock), so the 70 °C passive trips now cap cluster frequency; 110 °C critical trip remains the shutdown backstop. (`No trip points found for thermal id=0` is benign — the trip-less `gpu`/`gpuank2` monitor-only zones.)
- [x] GPU — **Mali-G52 (Bifrost MP2) live under mainline panfrost (built-in).** Added `gpu@60000000` to `ums512.dtsi` (compatible `sprd,ums512-mali`/`arm,mali-bifrost`, IRQ 60 ×3, `gpu_clk` core/mem/bus, `&pmu UMS512_POWER_DOMAIN_GPU_TOP`, reset, `vddgpu`, OPP 384–850 MHz), enabled in `ums512-1h10.dts`, plus a `sprd,ums512-mali` match in `panfrost_drv.c`; `CONFIG_DRM_PANFROST=y`. Validated on-device: `mali-g52 id 0x7402`, `shader_present=0x3`, `/dev/dri/renderD128`; devfreq enumerates all 5 OPPs (`simple_ondemand`, auto-ramps off the 26 MHz boot default to 384 MHz); a direct uAPI smoke test (GET_PARAM + CREATE_BO → nonzero GPU VA + mmap readback) passes, confirming the GEM/MMU datapath. **Key fix:** a latent bug in `drivers/clk/sprd/ums512-clk.c` — `ums512_clk_probe` used `platform_get_drvdata()` (a `sprd_clk_drvdata *`) directly as the reset `regmap`, so the GPU's reset-deassert (the first ums512 node to request a reset) panicked with PC=`0x0` in `sprd_reset_deassert`; fixed to `data->regmap` (matches `ums9230-clk.c`) — candidate for upstreaming. Still untested: actual shader execution via `SUBMIT` (needs mesa/panfrost userspace, not yet installed — no network on device).
- [x] SD card — **working at UHS-I SDR104.** `&sdio0` in `ums512-1h10.dts` just needed `status = "okay"` (it inherited `disabled` from the dtsi; supplies `vddsdcore`/`vddsdio` + UHS PHY delays were already present). Stock detects cards via the controller's internal `sd-detect-*-syscon` registers, but mainline `sdhci-sprd` sets `SDHCI_QUIRK_BROKEN_CARD_DETECTION` and ignores them, and this board has no dedicated CD GPIO (infinix-x6816d used `eic_sync 19`), so added `broken-cd` to fall back to mmc-core polling. On-device: `mmc0` enumerates a 60 GiB SDXC card as SDR104, `/dev/mmcblk0p1` mounts and reads fine.
- [x] UART — **both UARTs enabled and probing clean.** `&uart0`/`&uart1` were `disabled`; flipping to `okay` no longer hangs (the AP-APB `ranges` fix cleared the old uart0 hang). Two more fixes were needed: (1) the dtsi node's bare `clocks = <&ext_26m>` matches none of sprd_serial's named lookups, and a non-console port treats a missing `enable` gate as fatal (`-ENOENT`) — wired the three named clocks per vendor `whale.dtsi`: `uart`=`<&ap_clk CLK_UART{0,1}>`, `source`=`<&ext_26m>`, `enable`=`<&apapb_gate CLK_UART{0,1}_EB>`; (2) `CONFIG_SERIAL_8250` was claiming `ttyS0..7` (same `ttyS` dev_name/major as sprd_serial → `duplicate filename '/class/tty/ttyS0'` + `Cannot register tty device`) — disabled `SERIAL_8250`/`SERIAL_8250_CONSOLE` (no 8250 HW on this SoC). On-device: `ttyS0`+`ttyS1` register, console on `ttyS1`. Remaining `request {TX,RX} DMA channel failed, ret = -19` is benign (no `dmas` wired → PIO fallback). **This unit has no known broken-out UART pads**, so this is "enabled + clean boot, no regression," not a verified serial link.
- [x] Audio — **speaker playback working** (real-time, clean) via the full DSP-mediated VBC path.
  - *Stock HW:* in-PMIC codec `sc2730`, DSP-mediated VBC (`vbc-v4-dsp.c`, IPC over `AGDSP_CH_VBC_CTL`), digital codec, MCDT (R1) + agcp DMA transport. **Speaker = codec headphone path → external Awinic AW87391 smart-amp** on i2c2 `0x58`. NB: the amp is driven **over I2C** (`anbernic_rgds_amp_enable()` in `aw87390.c`), **not** the GPIO-9 pulse mechanism — that (and `/sys/kernel/extpa/*`) is vestigial on this board. Speaker uses the codec **HP** mixers, not the SC2730 class-D SPK pin (`SPKL Gain`/`SPKL Mixer` stay off).
  - **Done:** AGDSP boots on mainline (ported `sprd-audcp-boot`, `sprd,ums512-audcp-boot`; stock `l_agdsp` firmware in the initramfs; both AGDSP power domains reach full wake-lock), the full DSP-mediated ASoC stack (VBC/MCDT/digital-codec/card + AW87391 amp) is wired to ums512, AP↔AGDSP IPC round-trips, and the speaker plays cleanly at real-time throughput.
  - *Mixer dependency:* playback needs an `asound.state` (DAC→HPL/HPR→HP path switches + **`DSP VBC Profile Select = 961216512`**, the load-bearing AGDSP VBC-profile selector — silent at its default). Recipe captured in `docs/stock_mixer_{idle,during}.txt`; `alsactl store` persists it. Driver seeds the HP/DAC analog gains on DAC power-up and enables the **AG_IIS0 → audio-top** route at codec probe (defaults off → otherwise silent).
  - *Robustness fixes (2026-07-10):* honour the agcp-ahb null-check in `arch_audio_iis_to_audio_top_enable` (kills an `alsactl`-at-boot NULL-deref panic); gate codec digital-register + AG_IIS0 writes on `agdsp_can_access()` and pin the AGDSP core awake (idle `amixer` reads no longer fatal-SError); **ums512 R1 mailbox binding** — the DT mislabelled it `ums9230` (R2), so the inbox ISR read the wrong FIFO bits and the IRQ auto-disabled ("nobody cared").
  - *Also ported, dormant — AP-side i2s0:* the vendor `i2s` CPU-DAI + `all-i2s` null-codec card, proven working end-to-end (real-time `ap_dma`, completion IRQ fires — no hrtimer needed). But IIS0 is the stock `i2s_bt_sco0` **Bluetooth-SCO** link, not the speaker, so the card ships **disabled**. Key unlock was the DMA **request-UID** fix (`dmas` cell is the UID now that `dma_slave_config.slave_id` was removed upstream: `ap_dma 4/3`, not 5/6).
- [ ] Input — *stock HW:* gamepad via out-of-tree **`singleadc-joypad`** (`joypad-name = "retrogame_joypad"`, product `0x1101`). Registers a single EV_KEY+EV_ABS gamepad: face buttons `BTN_SOUTH/EAST/NORTH/WEST` (0x130–0x134), shoulders `BTN_TL/TR/TL2/TR2`, Start/Select/Back, and the **D-pad as ABS_HAT axes** (children use `linux,input-type=3`). The analog `abs_{x,y,rx,ry,z,rz}` axes + 6-way `amux`/`adc-power-ctl1-4` plumbing are declared but **inert on this stickless SKU** (shared family DTBO). An alternate **`sprd,spi-mcu-joy`** SPI-MCU joypad path also exists in the overlay (different HW rev). System keys via `gpio-keys`: Power (0x74), **Vol-Down (0x72) / Vol-Up (0x73)** — real volume-key GPIOs *do* exist — and Hall (0x58). NB: gpio-keys can't substitute for singleadc-joypad here — it would emit KEY_* (keyboard semantics) with no joystick node, which game frontends won't treat as a gamepad.
- [ ] Touchscreen — *stock HW:* **`goodix,gt9xx`** at i2c `0x14`, 720×720 (`0x2d0`), vcc gpio 0x10 / irq 0x90 / reset 0x91, embedded `cfg-group0` config blob. Mainline `goodix`/`Goodix-TS` may cover it (gt9xx is the older out-of-tree variant). Panel is up, so a natural next target.
- [ ] Sensors — *stock HW: Hall switch only.* No accel/gyro/mag/als/prox compatibles anywhere in the stock dts or overlay; the only sensor is the Hall switch (the `key-hall` gpio-keys entry, gpio 0x0f, `linux,code=0x58`). Earlier "likely has accel/gyro" guess is not supported by the stock DT.
- [~] Wi-Fi / Bluetooth — **Wi-Fi DONE, Bluetooth still to do.** *Stock HW:* single **`unisoc,marlin3lite_sdio`** WCN combo (Marlin3 Lite / SC2355) on the `71400000.sdio` bus, fanning out to `sprd,sc2355-sdio-wifi` (wlan), `sprd,mtty` → `ttyBT` (BT), `sprd,gnss`, and `sprd,marlin3-fm`. GPIOs: enable 0x8f, reset 0x5f, wakeup-ap 0x21, irq 0x5e; supplies avdd12/avdd33/dcxo18 + clk_32k.
  - *Wi-Fi — working, line rate both directions.* A from-scratch mainline SC2355 SDIO driver (`drivers/net/wireless/unisoc/`, `sc23xx_wlan{,_sdio}`) on the BSP `sprdwcn` bus (sdiohal). Associates + WPA2 4-way + DHCP, holds a stable link, and over iperf3 does **~25 Mbit/s up / ~176 Mbit/s down at 0 retransmits**. Getting there took: the firmware power-save wake handshake on the SDIO data path, honoring the all-zero FLOWCON credit reset, the RX BA reorder rewrite (collect-then-deliver outside `sta_lock`, timer arming, timeout off-by-one), TX-credit **backpressure** (netif stop/wake + park-on-starvation instead of drop) with a HOST_IDLE-only-when-idle fix for the reconnect flap, and the **A-MSDU** `last_msdu_of_mpdu` bit fix that unlocked download throughput. No mainline marlin3 driver existed; vendor reference under `vendor/linux-kernel-5-4-ums512/.../wcn/wlan/wlan_combo/sc2355/`.
  - *Bluetooth — not started.* `sprd,mtty` → `ttyBT` over the same combo (Marlin3 BT via `kernel5.4/wcn/bluetooth/driver/tty-sdio/`); needs its own port on top of the now-working WCN/SDIO bring-up.
- [~] USB host / OTG — **gadget confirmed working from cold boot** (CDC-ACM console enumerates on `boot_a` with no U-Boot handoff); **host mode still to be tested.** Earlier cold-boot enum `-71` deep-dive in [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md). *Stock HW:* controller `sprd,sharkl5pro-musb`, PHY `sprd,sharkl5pro-phy` (both already in mainline path), plus a **`linux,extcon-usb-gpio`** node for GPIO ID/VBUS detection — a possible host-detect mechanism worth evaluating against the role-switch dance.

## Polish-level targets
- [ ] PM / Suspend-Resume — Currently doesn't complete due to charger driver returning -19 mid-suspend.
- [ ] DDR devfreq / DDR-DVFS — *could be done, but will take some time.* No sprd devfreq driver in mainline (devfreq core/governors enabled, but no Unisoc driver); no DDR-DVFS DT nodes. Vendor has a large proprietary stack (`drivers/devfreq/sprd/` ddr-dvfs core + `sprd_governor_vote`, `apsys/` DPU/GSP/VSP DVFS, `sprd-top-dvfs`) coupled to `topdvfsctrl@322a0000`/`dmc-mpu` + SIPC to a remote DVFS coprocessor — a multi-week port. DDR free-runs at the firmware-set frequency (stable). Right-shaped path if ever wanted: a thin SMCCC-SIP devfreq driver (like `sprd-cpufreq-v2`), but none exists in-tree yet

Cross-reference `device/stock/dtb_stock.dts` whenever a node, supply, syscon, or
GPIO detail is unclear in mainline.

## Vendor driver source map (`vendor/linux-kernel-5-4-ums512/kernel_modules/`)

This is the **generic UMS512 Android BSP**, not a per-SKU tree — it carries
drivers for many sibling devices, so presence of a driver here does *not* mean
the part is on *this* board. Mapped against our stock-DT hardware:

- **Wi-Fi** → `kernel5.4/wcn/wlan/wlan_combo/**sc2355**/` is ours (matches overlay
  `sprd,sc2355-sdio-wifi`). The `merlion/` and `sc2332/` siblings in the same dir
  are **different chips — do not port those**. SDIO transport.
- **Bluetooth** → `kernel5.4/wcn/bluetooth/driver/**tty-sdio**/` (Marlin3 over
  SDIO, surfaces as `sprd,mtty` → `ttyBT`). `tty-pcie`/`tty-sipc*` are other transports.
- **FM** → `kernel5.4/wcn/fm/driver/**fm_sdio**/`. GNSS shares the marlin3 stack.
- **Audio** → `kernel5.4/audio_driver/sprd/` is the ASoC side (`codec`/`dai`/
  `machine`/`platform`); `kernel5.4/audio_driver/sprd_audio/` is the proprietary
  **AGDSP/SIPC** half (`agdsp_access`, `audiosipc`, `mcdt`, `audio_pipe`, …). The
  external `aw87xxx` speaker PA is wired *inside* the sprd ASoC machine driver
  (`sprd/machine/sprd_card/sprd-asoc-card-utils-hook*.c`), not as a standalone module.

**NOT in this tree** (Anbernic additions, sourced elsewhere):
- **Goodix `gt9xx` touchscreen** — no goodix code here at all; use mainline
  `goodix`/`Goodix-TS` (or the upstream out-of-tree gt9xx).
- **`singleadc-joypad` / `sprd,spi-mcu-joy` gamepad** — absent; the singleadc
  driver lives in handheld-distro trees (ROCKNIX/JELOS/Knulli), not the SPRD BSP.
- **`aw32257`/`bq2415x` charger** — absent (already solved on mainline `bq2415x`).

`kernel5.4/input/misc/` holds a large **generic sensor zoo** (`bma253`, `bmi160`,
`kionix`, `lis2dh`, `mc34xx`, `mir3da`, `stk8baxx`, `akm099xx`/`afx133` mag,
`ltr_558als`/`tcs3430` als, `vl53L0/L1` ToF) — none correspond to this board (stock
DT declares **Hall only**); useful only as a driver pick *if* a sensor ever turns up.
Likewise `input/touchscreen/` (focaltech/novatek/synaptics/…) does **not** include goodix.

## Subsystem detail

- **Display / DRM** — [docs/DISPLAY-BRINGUP.md](docs/DISPLAY-BRINGUP.md) (working recipe, panel data source, live-debug notes)
- **Power / PMIC / charger** — [docs/POWER-BRINGUP-NOTES.md](docs/POWER-BRINGUP-NOTES.md).
- **USB gadget / OTG** — [docs/WHAT-HAS-BEEN-TRIED-USB.md](docs/WHAT-HAS-BEEN-TRIED-USB.md).
