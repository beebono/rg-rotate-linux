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
</content>
