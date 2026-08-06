# A75 hw-DVFS bring-up: plan to port the realme-generation hwdvfs driver

**Status:** PORTED, awaiting on-device test. Written 2026-08-05; port landed
2026-08-05 as linux-7-1-sprd commit 0e405094d862 (pushed to rg-rotate).
Step 0 outcome: realme `third_pmic_cfg[DCDC_CPU1]` = 0x120 bit0 = the
DIALOG_EN bit we already set — inert as predicted, full port done instead.
Deviations from stock: `dvfs-blk-sd-syscon` made optional in the engine and
omitted from DT (boot-wedge, see below); no cpu-bin nvmem / multi-version —
base `operating-points` + base cluster tables (== T618 values) used.
Test procedure: see "Build & test" below.

## Why

The A55 (little cluster / DCDC_CPU0, ADI rail) does real hardware DVFS after the
enable-bit polarity fix. The A75 (big cluster / DCDC_CPU1, **external FAN53555 I2C
rail**) is parked at 26 MHz: the TOP-DVFS engine resolves the target voltage grade
(`VOTE_VOLTAGE=5`, `DVFS_VOLTAGE=5`) but never fires the I2C voltage transaction —
`DCDC_CPU1_DVFS_STATE_I2C` frozen at 4, `TUNE_VOLTAGE_I2C=0`, `CURRENT_VOLTAGE=0`,
`VOLTAGE_MEET=0`, CGM mux parked at `sel=0`.

Exhaustive comparison against a **working stock Android dual-boot on the same physical
board** proved:

- **Every software-settable TOP-DVFS register matches stock byte-for-byte** for the
  CPU1 I2C path (`0x098/0x0a0/0x0a4/0x120/0x138`, vsel payload `0x12c/0x130`
  populated). Only the *status/state* registers differ (broken vs working outcome).
- The aon hw-i2c master (`0x32060000`) and its clocks (`aon-i2c-clk`, `i2c-eb`) are
  **disabled on stock too** — the master/Linux-i2c path is a red herring; the DVFS
  engine drives the FAN53555 over its own autonomous hardware channel.
- No FAN53555 DT node exists even in stock's **live, post-u-boot-fixup** DT; the Linux
  `CONFIG_REGULATOR_FAN53555` driver is **unset** on stock (both realme and vendor
  ums512 `sprd_sharkl5Pro_defconfig`). The chip is pure-hardware-driven.
- No genpd power domain gates the path.

So everything *configurable* matches stock, yet our engine won't fire. The remaining
variable is the **driver itself**: we run the **older 4.14-generation** hwdvfs driver
(`CONFIG_ARM_SPRD_CPUFREQ_HW`, our `sprd-hwdvfs-normal.c` = 3174 lines), while stock
runs the **realme 5.4-generation** stack (`CONFIG_ARM_SPRD_HW_CPUFREQ_NORMAL` +
`_ARCH_UMS512` + `_PUBLIC`, realme `sprd-hwdvfs-normal.c` = 1905 lines). The A75 I2C
trigger gap most likely lives in a behavioral difference in our older engine's
DIALOG/I2C set path that isn't visible in static register state. Rather than keep
bisecting the old engine, port the generation stock demonstrably runs on this silicon.

Reference source (readable from the superproject git cache without re-adding the
submodule):
`git --git-dir=.git/modules/vendor/android-kernel-5-4-realme show HEAD:<path>`
Second copy: `vendor/linux-kernel-5-4-ums512` (same generation).

## Target driver stack (what stock builds)

From stock `docs/stock-android-reference/stock_kernel_config`:
```
CONFIG_ARM_SPRD_HW_CPUFREQ_NORMAL=m       # policy layer
CONFIG_ARM_SPRD_HW_CPUFREQ_ARCH_UMS512=m  # engine + ums512 archdata
CONFIG_ARM_SPRD_CPUFREQ_PUBLIC=m          # shared public data
CONFIG_SPRD_TOP_DVFS_DEVFREQ=m            # already ported (drivers/cpufreq/sprd-top-dvfs.c)
# CONFIG_REGULATOR_FAN53555 is not set    # keep unset
```

realme Makefile module composition (`drivers/cpufreq/Makefile`):
```
sprd-hwdvfs-policy-objs   := sprd-hwdvfs-cpufreq.o sprd-hwdvfs-debugfs.o   # _NORMAL
sprd-hwdvfs-ums512-arch-objs := sprd-hwdvfs-normal.o sprd-hwdvfs-ums512.o  # _ARCH_UMS512
sprd-cpufreq-public       := sprd-cpufreq-public.o                         # _PUBLIC
```

## File-by-file port mapping

Bring in from realme (adapt 5.4 -> 7.1), **replacing** our older-gen equivalents:

| realme file (lines) | role | our current equivalent to retire |
|---|---|---|
| `sprd-hwdvfs-normal.{c,h}` (1905) | core DVFS engine (MPLL/DCDC/cluster/**I2C set path**) | our `sprd-hwdvfs-normal.{c,h}` (3174, older) |
| `sprd-hwdvfs-archdata.{c,h}` (859) | generic structs + voltage-conversion fns, `pmic_array` | our `sprd-hwdvfs-archdata.{c,h}` (482, older) |
| `sprd-hwdvfs-ums512.c` (503) | ums512 archdata **tables** incl `ums512_third_pmic_cfg`, `ums512_volt_grades_tbl`, mpll/index tbls | (none — our tables live in DT + smaller archdata) |
| `sprd-hwdvfs-cpufreq.{c,h}` (1090) | cpufreq **policy** layer | our `sprd-cpufreqhw.{c,h}` (644) |
| `sprd-hwdvfs-debugfs.c` | debugfs | our `sprd-sysfs-normal.c` |
| `sprd-cpufreq-public.c` (81) | shared public data | (none) |
| `sprd-cpufreq-common.{c,h}` | shared helpers | our `sprd-cpufreq-common.{c,h}` (may already match) |

Keep `sprd-top-dvfs.c` (already ported, validated: device DCDCs now HW mode).
Leave `sprd-cpufreq-v2.c` alone (unrelated SMC driver, not built for us).

**Critical detail — the archdata is where the A75 fix probably lives.** realme's
`sprd-hwdvfs-ums512.c` carries `ums512_third_pmic_cfg[DCDC_NUM]` and drives
`sprd_dvfs_third_pmic_enable()` in the common-init loop. Our current port is **missing
`sprd_dvfs_third_pmic_enable()` entirely**, and our archdata has no `third_pmic_cfg`.
That is the single most suspicious delta for "engine resolves grade but never issues
the I2C transaction," because third-pmic-enable is what arms the I2C/DIALOG channel for
DCDC_CPU1. Verify this hypothesis first (see step 0) — it may even be portable as a
point-fix without the full re-port.

## Step 0 (do FIRST — cheap, may pre-empt the whole port)

Before the full port, test the isolated hypothesis:
1. Read realme `sprd_dvfs_third_pmic_enable()` (sprd-hwdvfs-normal.c ~line 368) and
   `ums512_third_pmic_cfg` (sprd-hwdvfs-ums512.c ~line 291) for the exact reg/bit.
2. Add the equivalent to our older engine's `sprd_cpudvfs_common_init` per-DCDC loop
   (we already parse `third-pmic-used`; wire a `third_pmic_cfg` reg/bit and set it when
   `i2c_used`). NB memory says `third_pmic_cfg` may target `0x120`
   (`DCDC_CPU1_TYPE_SEL_CFG.DIALOG_EN`) which we ALREADY set via
   `supply-type-sel = <0x120 0 1>` — if so this is inert and the fix is genuinely deeper,
   confirming the full re-port is required. Either outcome is decisive.

## Config / build changes (7.1 tree)

1. `drivers/cpufreq/Kconfig.arm`: add `ARM_SPRD_HW_CPUFREQ_NORMAL`,
   `ARM_SPRD_HW_CPUFREQ_ARCH_UMS512` (depends on the former),
   `ARM_SPRD_CPUFREQ_PUBLIC`. Copy help text from realme `Kconfig.arm`.
2. `drivers/cpufreq/Makefile`: add the three module composition lines above.
3. `arch/arm64/configs/ums512_defconfig` **and** in-tree `.config`: set the three
   `=y` (we build in, not modules), **drop** `CONFIG_ARM_SPRD_CPUFREQ_HW`
   (retire the old gen), keep `CONFIG_REGULATOR_FAN53555` unset,
   keep `CONFIG_SPRD_TOP_DVFS` path.
4. Remove old-gen files from the Makefile obj line (our current
   `ARM_SPRD_CPUFREQ_HW += sprd-cpufreqhw.o sprd-hwdvfs-normal.o
   sprd-hwdvfs-archdata.o sprd-cpufreq-common.o sprd-sysfs-normal.o sprd-top-dvfs.o`
   — keep `sprd-top-dvfs.o`, move it under a config that stays enabled).

## Device-tree changes

The realme-gen driver reads tables from **archdata**, not DT. Our board DT
(`ums512-rg-rotate.dts`) currently carries old-gen bindings that must be reconciled:

- **`dvfs-dcdc-cpu1-supply` node:** reduce to stock's minimal live form —
  `third-pmic-used; chnl-i2c-used; pmic-type-num = <2>; slew-rate = <4000>;
  tuning-latency-us = <0>;` (see `docs/stock-android-reference/stock_live_booted.dts`
  `dvfs-dcdc-cpu1-cfg`). **Delete** `voltage-grade`, `voltage-grade-num`,
  `voltage-up-delay`, `voltage-down-delay`, `supply-type-sel`, `top-dvfs-i2c-state`,
  `chnl-in-i2c` — these become archdata in the new gen.
- **`cpudvfs-dev@322a8000`:** align compatible/property names to what realme's
  `sprd-hwdvfs-normal.c` `of_match`/parse expects (diff against stock live node at
  `docs/stock-android-reference/stock_live_booted.dts` line ~4907, and
  `docs/decomp_stock.dts` `cpudvfs-dev@322a8000`). Our node currently has
  `status="disabled"` — stock's is enabled; confirm the enable + `mpll-cells`,
  `apcpu-dvfs-dcdc-cells`, cluster child bindings match the new parser.
- **`topdvfsctrl@322a0000`:** already aligned by the top-dvfs port (compatible
  `sprd,topdvfs-dev` added, mm/modem subsys eb fixed). Keep.
- Cross-check every DT property name the realme engine reads (`chnl-i2c-used` vs our
  `chnl-in-i2c`, `dvfs-blk-sd-syscon` vs our `dvfs-blk-dcdc-sd`, etc.) and switch our
  DT to the realme spellings. **Do NOT** re-add `dvfs-blk-sd-syscon`/block-shutdown —
  proven to wedge boot until the rail works (see memory).

## 5.4 -> 7.1 API adaptations (expect these)

- `platform_driver.remove` returns **void** in 7.1 (not int) — hit already in the
  top-dvfs port.
- `i2c_driver.probe` signature: 7.1 uses `probe(struct i2c_client *)` (no
  `const struct i2c_device_id *`). realme's `cpudvfs_i2c_probe` takes the old 2-arg
  form. (Only matters if we keep the i2c_client path — it's optional/NULL for us; can
  drop it since no FAN53555 DT node, matching stock.)
- regmap / syscon / of APIs are largely stable; watch `devm_ioremap_resource`,
  `syscon_regmap_lookup_by_phandle_args` arg counts.
- cpufreq core: `.init/.exit/.target_index` hooks and `cpufreq_generic_attr` may have
  shifted; the policy layer (`sprd-hwdvfs-cpufreq.c`) will need the most churn. Memory
  note: our old policy layer is "byte-identical logic" to stock's, so if the policy
  port is painful, our existing `sprd-cpufreqhw.c` may be reusable against the new
  engine — but prefer the matching-generation policy to avoid subtle ABI mismatch.
- OPP tables: realme-gen derives grade voltages from `operating-points`/`dev_pm_opp`
  per cluster. Confirm our cluster OPP tables exist and carry voltages (the vsel comes
  from `pmic_data` conversion of the OPP microvolts, not a DT vsel table anymore).

## Build & test

- Cross-build in `src/linux-7-1-sprd`:
  `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j12 Image dtbs`
- Deploy: this repo's ROCKNIX kernel is built by CI from the **pushed submodule
  branch** (`rg-rotate` on `beebono/linux-mainline-sprd`). Full kernel change =
  commit + push the submodule. **DTB-only** changes can be dropped straight to the
  device: `scp .../ums512-rg-rotate.dtb root@192.168.1.25:/flash/device_trees/`
  (remount `/flash` rw first; keep a `.bak`).
- Live A75 test harness (unchanged): `sshpass -e ssh root@t618.local` (pw `rocknix`,
  IP `192.168.1.25`); force OPP via
  `echo <hz> > /sys/devices/system/cpu/cpufreq/policy6/scaling_{min,max}_freq`;
  pin load `taskset -c 6 sh -c 'while :; do :; done'`; measure
  `perf stat -e cpu-cycles -C 6 sleep 2`. Success = ~2 GHz (not 52M cyc/2s = 26 MHz)
  and `devmem 0x322a009c` leaves `0x44` (STATE_I2C off 4) with `0x14c` TUNE_VOLTAGE_I2C
  non-zero.
- Sanity after boot: `dmesg | grep -i dvfs`, confirm A55/policy0 still scales (do not
  regress the working little cluster).

## Risks / open questions

- **Sizable change.** New engine + archdata + policy + public + Kconfig/Makefile/
  defconfig + DT rework. Budget a multi-session effort; keep the working A55 path
  from regressing (bisect by building the new stack but leaving old `.config` symbol
  as fallback until proven).
- **May still not fix A75.** If the blocker is truly outside all driver-settable state
  (an autonomous-channel hardware/firmware sequencing prerequisite), even the exact
  stock driver could stall — but it's the strongest remaining lever because it's the
  code proven to work on this silicon. Step 0 de-risks this cheaply.
- **Bootloader delta.** Our custom u-boot runs `apcpu_dvfs_init`/`fan53555_config`
  (slew only); stock u-boot does no DVFS writes. Untested whether our extra u-boot init
  leaves the engine in a state the kernel can't recover. If the full port doesn't fix
  it, next lever is neutralizing that u-boot init to match stock (separate experiment).
- DT parser mismatch is the most likely build/boot snag; diff property names carefully
  against `docs/stock-android-reference/stock_live_booted.dts` (ground truth, u-boot
  fixups applied).

## Reference artifacts captured this session (in-repo)

- `docs/stock-android-reference/stock_kernel_config` — stock's full kernel config
- `docs/stock-android-reference/stock_live_booted.dts` — live post-fixup stock DT
- `docs/stock-android-reference/stock_clk_summary.txt` — stock clock states
- `docs/dvfs-working-regmaps/*_2ghz.txt` — stock topdvfs/pmu regmaps at 2 GHz

---

## 2026-08-06 outcome: A75 runs 2.002 GHz (bypass mode); real voltage scaling still open

State shipped on `rg-rotate` (kernel `40c0a65c37f5`) + spl branch `cm4-defer` (`435e7eb`):
- realme-gen hwdvfs stack + `VOLTAGE_MEET_BYP` (0x98 bit0) baked into archdata for
  DCDC_CPU1 → full frequency ladder, PMU-verified 2.002 GHz, stable under load.
  Voltage is pinned at the FAN53555's power-on grade (top grade per stock idle
  readings) — correct for 2 GHz, wasteful at idle.
- SPL `CONFIG_SPL_FW_CM4_DEFER` (flashed to eMMC boot0/boot1, backup in
  device/backup/boot0.bak): AON 0x8c writable on SD boots.
- pmsys/sipc/sensorhub kernel stack cherry-picked (sprd_pmsys rproc loads
  sprd/pm_bootcode.bin + sprd/pm_sys.bin, staged in extra-firmware/T618/sprd).

### Definite next steps for actual voltage movement (in order)

1. **Rebuild ROCKNIX and confirm the pmsys rproc boots the CM4 kernel-side every
   boot**: `0x327d0124 == 0xc1`, PMU `0x774` deep-sleep count advancing, the three
   rpmsg devices present. (Liveness rules: never devmem SP IRAM 0x800000 unless the
   SP is known awake — it wedges the AP bus.)
2. **Check whether a CM4 booted *before* cpufreq probes changes anything**: with
   the rproc bringing pm_sys up early, see if `STATE_I2C` ever leaves 4 / 
   `CURRENT_VOLTAGE` populates once the engine posts a fresh vote (temporarily
   clear 0x98 bit0 via devmem to un-bypass and watch 0x9c). Today's manual load
   came up long after the request latched; ordering may matter.
3. **If still stuck: SIPC handshake theory.** The DFS service inside pm_sys may
   only start after the AP opens its SIPC channels (the sbuf OPEN/ack added in
   `71144b21`). Compare `0x9c` before/after the rpmsg devices appear. Also look at
   the vendor 5.4 `sprd_dfs`/`dfs_freq` driver — stock may send an explicit
   "DVFS enable" smsg the mainline stack never sends.
4. **If still stuck: channel state-machine reset.** The I2C request latched at
   state 4 may need the DVFS module's i2c channel re-armed: candidates are
   toggling `DCDC_CPU1_SW_DVFS_CTRL` (0x94 bit0 SW_TUNE_EN) with an explicit SW
   tune, or a full DVFS module eb toggle (aon 0x4 bit7 — risky live, do it from
   the driver at probe before the first vote).
5. **Ground truth on the rail** whenever convenient: multimeter on the DCDC_CPU1
   inductor across a forced 1.23 GHz ↔ 2.0 GHz swing; or once the channel works,
   `0x9c` CURRENT_VOLTAGE becomes self-reporting.
6. **When the channel works**: delete `ums512_vol_meet_byp_cfg` (archdata) and the
   `sprd_dvfs_vol_meet_bypass()` call — grep for "voltage-meet" in
   drivers/cpufreq. Then re-check idle power and suspend (pm_sys also owns
   deep-sleep paths), and re-verify thermals.

Bonus unlocked by the same stack: sensor hub (ICM-42607 accel/gyro) — see the
`t618-sensors-behind-cm4-sensorhub` memory; opcode downloads already confirmed
accepted, calibration-config send is the next untested step there.
