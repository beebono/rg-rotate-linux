# Rebase survey: our 6.16 fork → Otto Pflüger's 7.1 line

Goal: decide what to rebase onto the bleeding-edge Unisoc mainline tree. Captured
2026-06-28 with both trees checked out side by side:

- **Ours:** `src/linux-6-16-sprd` (branch `ums512`, base v6.16.0).
- **Upstream:** `src/linux-7-1-sprd` from `codeberg.org/ums9230-mainline/linux`
  (Otto Pflüger). Branches: `ums9230` (base v7.1-rc1) and `ums9230-opencp`
  (adds open-source coprocessor boot).

## Lineage (important framing)

Our tree **is a fork of Otto's tree** — our `ums512` branch history still contains
his `SC2730 PMIC`, `UMS9230 SoC`, WiFi/BT/etc. commits at the bottom. We stacked
ums512 (RG Rotate) bring-up on top. So this is not "merge two strangers"; it is
"replay our bring-up deltas onto a newer revision of the same line."

Version gap: **v6.16.0 → v7.1-rc1**.

## A. Upstream now has what we built independently (candidates to DROP ours, take theirs)

Otto's line gained generic **ums512 SoC support** since we forked. Prefer upstream
versions unless our diff carries a device-specific fix (see section D):

| Area | Ours (6.16) | Upstream 7.1 | Action |
|---|---|---|---|
| ums512 clock | `ums512-clk.c` (+reset map inline) | `ums512-clk.c` (reset map removed, 251-line diff) | take theirs; re-verify panfrost fix (D) |
| ums512 dtsi | `ums512.dtsi` (heavily hacked, **1812-line diff**) | `ums512.dtsi` (clean) | **biggest rebase cost** — replay our deltas onto theirs |
| board dts | `ums512-1h10.dts` + `ums512-infinix-x6816d.dts` | `ums512-1h10.dts` (generic) | base RG Rotate dts on their 1h10 |
| ums512 bindings | `sprd,ums512-clk.yaml` etc. | present | take theirs |
| power domains | `pmdomain/sprd` ums512 | present | diff & take theirs |

## B. Upstream REORGANIZED — our patches may be obsolete or need re-homing

- **Reset moved out of the clk driver.** Ours: reset map lives in `ums512-clk.c`
  + `dt-bindings/reset/sprd,ums512-reset.h`. Upstream: `clk/sprd/reset.c` keyed by
  `sprd,ums9230-reset.h`; the ums512 clk reset map is gone. **Our panfrost
  reset-drvdata fix (`sprd_reset_deassert` PC=0x0) lives in this exact code that
  changed — re-verify whether the bug still exists upstream or was fixed by the
  reorg.** (See memory `gpu-panfrost-bringup.md`.)
- **pinctrl:** ours `pinctrl-sprd-ums512.c`; upstream ships `pinctrl-sprd-ums9230.c`
  (no -ums512). Check whether ums9230 pinctrl data covers ums512 pins or we keep ours.
- **cpufreq:** ours is a pile of vendor-derived files
  (`sprd-cpufreqhw.c`, `sprd-hwdvfs-*`, `sprd-cpufreq-common.*`, `sprd-sysfs-normal.c`).
  Upstream has a single clean **`sprd-cpufreq-v2.c`**. Strongly prefer upstream;
  re-confirm our cpufreq result (topology_cluster_id fix — memory
  `thermal-cpufreq-bringup.md`) still holds on it.
- **hw-channel i2c:** ours `i2c-sprd-hw.c`; upstream `i2c-sprd-hw-v2.c`. Take v2,
  re-verify the i2c4 / ap-apb addressing fix (memory `charger-aw32257-i2c4-blocker.md`).

## C. Upstream has NEW subsystems we lack (pull candidates, post-rebase)

- **`ums9230-opencp` branch:** open-source ELF boot of the PMSYS/CP coprocessor
  (`sprd_pmsys_opencp.c`), `sprd_common`, `sprd_modem`, `sprd_wcn`, SIPC rpmsg,
  gnss, bluetooth-over-SoC, integrated WiFi. Relevant long-term; **not** an audio fix
  (the `agdsp` audio-DSP node is identical between branches).
- **IIO sensor hub:** `drivers/iio/common/sprd_shub/*` + accel/gyro/light/magn/prox
  (`sprd_shub_*`). Path to accelerometer/ALS on the handheld.
- **Camera:** `media/platform/sprd/camsys/` ISP/DCAM (ums9230-targeted).
- **GNSS:** `drivers/gnss/sprd.c`.
- **Audio:** a distinct `ASoC: Add support for the UMS9230 digital codec` commit
  (vs our `ums9230-digital.c`); newer VBC/sc2730 revs — see section E.

## D. Our bring-up deltas that MUST survive the rebase (load-bearing — see CLAUDE.md)

These are device-specific and (mostly) not upstream. Carry forward explicitly:

- USB `dr_mode = "otg"` + initramfs role-switch dance (memory `usb-gadget-otg-and-cleanup.md`).
- Display free-run: both DPI-halt halves disabled, DSI_MODE_CFG=0; cold kernel-native
  panel init (`prepare_prev_first` + early clock-lane arm) (`cold-init-prepare-prev-first.md`).
- ap-apb `ranges` identity + offset child addrs; i2c4 @0x00700000; sdio offset fix
  (`charger-aw32257-i2c4-blocker.md`).
- eMMC/SD `vmmc`/`vqmmc` supplies wired (drops `*_ignore_unused`).
- sdio0 `status=okay` + `broken-cd` for microSD (`sdcard-sdio0-bringup.md`).
- uart0/1 named clocks + `SERIAL_8250` disabled (`uart-bringup.md`).
- `audcp_boot` node (`sprd,ums512-audcp-boot`, loads `sprd/ums512-agdsp.bin`) and all
  audio bring-up work in `sc2730.c` / `vbc-v4-dsp.c` / machine driver.
- Charger bq24158/AW32257 on i2c4; SC2730 FGU; thermal/cpufreq cooling wiring.

## E. Audio-specific (this is what triggered the survey)

Upstream is **not ahead** on the audio wall and in fact TRIMMED the path:

- **sc2730.c:** upstream *removed* the AUDIF soft-reset (`sc2730_audif_reset_event`,
  `AUD_CFGA_SOFT_RST`) — i.e. Otto tried and dropped the exact thing we added in
  session 5. Independent confirmation it is a dead end; **do not re-add on rebase.**
- **vbc-v4-dsp.c (2026 rev):** removed the IIS-master surface and the TX-mux `-EBUSY`
  check (both already "proven NOT the gate" for us); rest is clang-format churn. The
  added `#include <linux/firmware.h>` is an **unused leftover** — no DSP firmware
  loading was added. Not a lead.
- `agdsp` node unchanged between branches: reset-controlled AUDCP core
  (`RESET_PMU_APB_AUDCP_AUDDSP_SOFT_RST` + `AUDCP_SOFT_RST`), firmware memory-region.
  The 48 kHz DA-clock / VBC-scene wall (AUDIO-THEORY.md hyp #2) is **unsolved upstream
  too**. Still the right place to dig: AUDCP reset/boot sequence vs what we do.

## Recommended rebase strategy (for next session)

1. Branch off upstream `ums9230` at v7.1-rc1.
2. Port the **RG Rotate board dts** onto their `ums512-1h10.dts` + `ums512.dtsi`,
   re-applying section-D deltas one subsystem at a time (each is independently
   bootable/testable on this device).
3. Take upstream's clk/reset/pinctrl/cpufreq-v2/i2c-hw-v2; re-verify the four fixes
   flagged in B against the new code (panfrost reset, cpufreq topology, i2c4 addr).
4. Defer section-C new subsystems (sensors, camera, opencp) until the device boots
   clean on 7.1.
5. Audio: carry our deltas forward as-is; do **not** re-add the AUDIF soft-reset.

## Session progress (2026-06-29)

- Branch `rg-rotate` cut off upstream `ums9230` (the forward v7.1 line) and
  pushed to `beebono/linux-mainline-sprd`. `ums9230-opencp` confirmed as a
  **feature branch stuck at 6.18-rc4** (merge-base = Linux 6.18-rc4; ums9230 is
  46499 commits ahead, opencp only 110) — its 110 commits are the section-C
  payload (camera/wifi/bt/gnss/sipc/opencp/UMS9230 audio/sensors/panel) and are
  a deferred cherry-pick layer, NOT a base. No git merge-base between our 6.16
  `ums512` and upstream `ums9230` → an automated `git rebase --onto` is out;
  this is a manual subsystem-by-subsystem re-port.
- **Key reframing of the "1812-line dtsi diff":** upstream's `ums512.dtsi` is
  918 lines vs our 2670. The gap is mostly upstream **not having** the
  peripheral SoC nodes at all — no ap_gpio, pinctrl, pwm, dpu/dsi/disp/
  iommu_disp, hsphy/usb, i2c2/i2c4, audio codec/VBC/pcm graph, cpufreq-dvfs
  supplies, or even a real Mali device node (only `gpu_clk` syscon). So the
  bulk of the work is **SoC-dtsi-level node porting**; the board dts is thin.
  Upstream's `sc2730.dtsi` does provide vddsdcore/vddsdio/vddemmccore/vddusb33/
  sc2730_fgu/sc2730_codec.
- **Stage 1 landed:** new `arch/arm64/boot/dts/sprd/ums512-rg-rotate.dts`
  (+ Makefile) wiring only what upstream's dtsi backs today — serial, microSD
  (supplies+broken-cd+phy delays), eMMC, SC2730 fuel-gauge battery telemetry.
  All other subsystems are staged as an inline checklist in that file, to be
  un-staged as their SoC nodes are ported into the 7.1 dtsi.
- **hwspinlock** SoC node was missing from upstream 7.1 ums512.dtsi (sc2730
  ADC/efuse → fgu depend on `&hwlock`). Ported back under `aon: bus@32000000`
  at offset `0x7f0000`.
- **gpio + pinctrl ported (DONE).** ap_gpio@70000 + pinctrl@450000 added to
  ums512.dtsi (offset addressing under the aon bus); `pinctrl-sprd-ums512.c`
  copied from 6.16 (framework byte-identical — only cosmetic %pOF churn in the
  core; ums9230 pinctrl data does NOT cover ums512 pins, so the dedicated
  driver is kept) + Makefile/Kconfig (PINCTRL_SPRD_UMS512). Full Image + dtb
  build clean. NOTE: upstream's aon bus already uses the offset child-address
  scheme our 6.16 i2c4/charger fix had to add by hand — re-check if that fix is
  partly free upstream when we reach i2c4.
- **defconfig:** seeded a tracked `arch/arm64/configs/ums512_defconfig`
  (generic arm64 defconfig + sprd deltas; build with `make ums512_defconfig`).
  Grows per-subsystem. NOTE: 7.1 build invocation differs from the 6.16 README
  (`make defconfig`) — update parent README when docs are refreshed.
- **i2c + charger ported (DONE).** i2c0..i2c4 controllers added to ums512.dtsi
  apb@70000000. CONFIRMED the flagged win: upstream's apb bus already uses the
  offset child-address ranges (`<0 0x0 0x70000000 0x10000000>`) that our 6.16
  ap-apb fix added by hand — i2c4 lands at 0x00700000 with NO bus rework. Board:
  i2c4 pinmux (SIMCLK2/SIMDA2 func2/AF1 + WPU) + charger@6a bq24158 un-staged.
  `i2c-sprd.c` byte-identical 6.16→7.1. Configs: I2C_SPRD, CHARGER_BQ2415X.
- **USB ported (DONE).** hsphy (anlg_phy_g2) + usb@5fff0000 (under soc, 2-cell)
  added to ums512.dtsi. musb sprd.c: upstream's ONLY change vs our 6.16 is a new
  `musb_set_state(OTG_STATE_B_IDLE)` on the DEVICE role — it still doesn't assert
  a gadget session, so our board hack (musb_start + force B_PERIPHERAL + DEVCTL
  SESSION + POWER SOFTCONN) is re-applied. hsphy driver byte-identical.
  Configs: USB_MUSB_SPRD, PHY_SPRD_USB2, gadget serial stack, SERIAL_SPRD(+con).
  OPEN: cold-boot/re-enum -71 still unsolved (carried from 6.16). Considering
  whether restoring upstream's B_IDLE before our forcing helps re-enum (note:
  musb_set_state is a pure otg_state setter — no HW side effects — so B_IDLE is
  immediately superseded by B_PERIPHERAL with no consumer in between; mechanically
  inert here, harmless to A/B on device but not a likely -71 lever).
- **Display — DT + drivers ported, FREE-RUN HACKS PENDING.** Ported dpu/
  iommu_disp/dsi (mm simple-bus), display-subsystem, pwm, dphy clocks into
  ums512.dtsi; board framebuffer/backlight/lcd-regs/panel un-staged. The
  out-of-tree ROCKNIX panel-generic-dsi driver ported (only needed a linux/hex.h
  include for hex2bin). KEY: the upstream 7.1 sprd DRM stack (dpu/dsi/drm/gem/
  megacores) is the CLEAN base — our 6.16 "diff" was mostly OUR debug
  instrumentation (int-status logging, rd_pkt dumps) + the device hacks. It
  compiles clean against 7.1. Configs: DRM_SPRD, DRM_PANEL_GENERIC_DSI, PWM_SPRD,
  BACKLIGHT_PWM. *** STILL TODO (untestable here, needs device): re-apply the
  load-bearing hacks on the clean drivers — sprd_dpu.c free-run (clear
  BIT_DPU_DPI_HALT_EN, don't poke DPU RUN), sprd_dsi.c DSI_MODE_CFG=0 +
  prepare_prev_first cold-init + early clock-lane arm, DPI polarity, and check
  megacores_pll.c (24-line delta). Refs: DISPLAY-KNOWN-GOOD-DSI-STATE.md,
  cold-init-prepare-prev-first memory. Upstream does the OPPOSITE (sets HALT_EN,
  DSI_MODE_CFG=1) so without the re-apply the panel blanks. ***
- **MILESTONE: full Debian boots on 7.1** (kernel 7.1.0-rc1-sprd-ums512+),
  login over ttyGS0, eMMC rootfs pivot works. Core platform (clocks, DMA, eMMC,
  USB gadget, hwspinlock, pinctrl, i2c) all up. Three bugs caught by flashing
  early: (1) gadget built as modules w/ module-less initramfs → rebased config
  on real 6.16 .config; (2) 7.1 phy-sprd-usb2 only bound ums9230-hsphy + lacked
  the cold-boot ref-clock/soft-reset fix → re-added ums512-hsphy + the fix;
  (3) no dtsi aliases → eMMC drifted mmcblk3→mmcblk1 → added mmc/i2c aliases.
- **Display drivers carried (DONE, on-device validation pending).** The proven
  6.16 sprd_dpu/dsi/megacores_pll COMPILE CLEAN against the 7.1 DRM core, so
  carried wholesale (free-run, cold-init reset+clock-prep, prepare_prev_first)
  rather than hand-porting the interdependent hacks onto upstream.
- **Local commits on `rg-rotate` (NOT pushed yet — pushing when nearer 6.16
  parity):** board+hwspinlock, gpio+pinctrl, defconfig(+real-6.16 rebase),
  i2c+charger, usb+hsphy(+coldboot phy fix), mmc aliases, display-DT+panel-driver,
  display-drivers. Remaining: GPU, cpufreq, audio (feature ports next session).
