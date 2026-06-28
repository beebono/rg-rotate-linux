# CPU cpufreq (register-level DVFS) — forward-port plan

Mainline cpufreq on the RG Rotate (UMS512 / T618 / sharkl5pro). The upstream
`sprd-cpufreq-v2` SMC driver is a **dead end** here: our stock `sml` implements no
SIP DVFS (every `SPRD_SIP_SVC_DVFS_*` SMC returns `0xffffffff` = NOT_SUPPORTED).
The retail device drove CPU DVFS **at the register level** via `sprd,sharkl5pro-cpudvfs`
(MMIO `0x322a8000` + a topdvfs syscon at `0x322a0000`). This plan forward-ports the
vendor register-level driver stack to kernel 6.16.

## Source

**Driver C:** `vendor/android-kernel-rp2p` (Retroid Pocket 2+, also T618, branch
`android-9.0`, kernel 4.14.98) — `drivers/cpufreq/`. Already ported & compiling in
`src/linux-6-16-sprd` (kept per decision; diff vs the 4-14-sprd copy is benign — a
binned-OPP-name refactor + a safe `kzalloc` over-alloc).

**Device tree (REVISED):** transcribe from `vendor/linux-kernel-4-14-sprd` (the
canonical Unisoc 4.14 drop, real silicon — NOT the RP2+ HAPS dtsi):
- `arch/arm64/boot/dts/sprd/sharkl5Pro.dtsi` — `cpudvfs-dev@322a8000` (line ~1516)
  + `topdvfsctrl@322a0000` (~1456) + mpll/apcpu nodes. Bindings (`cpudvfs-clusters`,
  `cluster-devices`, `map-tbl-regs`, `*-dvfs-tbl`) match our ported driver exactly.
- `ums512.dtsi` (~667) — real **T618** CPU OPP tables (`cpufreq-clus0/1` +
  scu/periph/gic sub-clusters). Resolves the OPP-derivation risk entirely.
- `ums512-1h10.dts` (~233) — the two `dvfs-dcdc-cpuN-supply` voltage-grade nodes
  (exact board-name match to ours).

The **stock DTB** (`device/stock/dtb_stock.dts`) also has a real T618 `cpudvfs-dev`
node, but it matches a *newer* stock driver vintage we have no source for
(`host-cluster-cells`/`_tbl_T618`/`belong-dcdc-cell` bindings — no driver in any tree
parses them), so it is NOT usable as a transcription source.

## Files to port (into `src/linux-6-16-sprd/drivers/cpufreq/`)

| File | Role | Notes |
|------|------|-------|
| `sprd-cpufreq-common.{c,h}` | OPP/binning glue, `sprd_cpudvfs_device`/`ops`, `cpufreq_datas[]` | our in-tree `vendor/android-kernel-ums512` copy is the same but with a `__weak` stub — use the RP2+ full copy |
| `sprd-cpufreqhw.{c,h}` | SoC-agnostic cpufreq **policy** driver | self-registers `sprd-hardware-cpufreq` pdev via `device_initcall` |
| `sprd-hwdvfs-normal.{c,h}` | register **engine**, platform_driver on `sprd,sharkl5pro-cpudvfs` | 80 KB; pure regmap/readl-writel + DT parse + sysfs |
| `sprd-sysfs-normal.c` | kobject debug sysfs | optional but small; keep |

**Drop:** `sprd-hwdvfs-archdata.{c,h}` (static `ums312_dvfs_private_data` for
sharkl5/ums312 only — sharkl5pro match has **no `.data`**, it is fully DT-driven;
NULL match-data is handled in `sprd_cpudvfs_probe`). Also drop `sprd-cpufreqsw.c`
(legacy 32-bit sharkl3/pike2/sharkle path) and the `sharkl5/roc1/orca` of_match
entries + their archdata.

## Driver architecture (so the port preserves it)

- `sprd-hwdvfs-normal.c`: `platform_driver` matched on `sprd,sharkl5pro-cpudvfs`,
  `subsys_initcall`. probe: `devm_ioremap_resource` the cpudvfs regs, get the
  `sprd,syscon-enable` (aon_apb) regmap, `dvfs_device_dt_parse()` the cluster
  tables, `sprd_cpudvfs_common_init()`, then registers a `sprd_cpudvfs_device`
  (the 8 ops) via `sprd_hardware_dvfs_device_register()`.
- `sprd-cpufreqhw.c`: `device_initcall` creates the `sprd-hardware-cpufreq`
  platform device; its `module_platform_driver` probe calls
  `cpufreq_register_driver()` and pulls the engine ops through
  `sprd_hardware_dvfs_device_get()`.
- **Init order matters:** engine `subsys_initcall` must register the dvfs device
  before the policy driver's `device_initcall` consumes it. Preserve both initcall
  levels.
- topdvfs (`0x322a0000`) is consumed as a **syscon regmap**
  (`syscon_node_to_regmap` on the `topdvfs-controller` phandle), NOT a driver — no
  topdvfs driver port needed for CPU. apsys (`0x1700000`) is unrelated (multimedia).

## 4.14 → 6.16 API deltas (the actual work)

All concentrated in the small files; the 80 KB engine is almost pure regmap I/O.

1. **`cpufreq_table_validate_and_show()`** (cpufreqhw.c:366) — removed (~5.5).
   Replace with `policy->freq_table = freq_table;` (OPP path already built the
   table via `dev_pm_opp_init_cpufreq_table`).
2. **`CPUFREQ_STICKY`** flag (cpufreqhw.c:524) — removed. Delete it.
3. **`cpufreq_driver.exit`** now returns `void` — change
   `sprd_hardware_cpufreq_exit` signature (drop `return ret;`).
4. **`platform_driver.remove`** now returns `void` (remove_new rename completed
   6.11) — both platform drivers (`sprd_hardware_cpufreq_platdrv`,
   `sprd_cpudvfs_driver`) and their `*_remove` funcs.
5. **`i2c_driver.probe`** single-arg now — `cpudvfs_i2c_probe(client, id)` →
   `cpudvfs_i2c_probe(client)`. (i2c DCDC regulator path; sharkl5pro uses
   `sprd,cpudvfs-regulator-sharkl5pro` — confirm whether our SC2730 DCDC needs it
   or is pmic-internal; may be droppable.)
6. **`devm_ioremap_resource`/`syscon_regmap_lookup_by_phandle`** return `ERR_PTR`
   — fix the `if (!base)` / `if (!aon_reg)` checks to `IS_ERR()` (pre-existing
   latent bug). Prefer `devm_platform_ioremap_resource`.
7. **`np->full_name` with `%s`** → `%pOF` with the node (cosmetic; 3 sites).
8. `.owner = THIS_MODULE` in driver structs — harmless/redundant, leave or drop.
9. sysfs `sprintf` → `sysfs_emit` (optional cleanliness).

## Kconfig / Makefile

- Add `CONFIG_ARM_SPRD_CPUFREQ_HW` (bool/tristate) gating the 4 files; keep it
  separate from the existing `CONFIG_ARM_SPRD_CPUFREQ_V2` (which we leave for
  ums9230). Build `=y` (cpufreq core is built-in here).
- `drivers/cpufreq/Makefile`: `obj-$(CONFIG_ARM_SPRD_CPUFREQ_HW) +=
  sprd-cpufreqhw.o sprd-hwdvfs-normal.o sprd-cpufreq-common.o sprd-sysfs-normal.o`.

## Device tree

**CORRECTION (verified during port):** `device/stock/dtb_stock.dts` matches a
*different* driver vintage — most of the RP2+ driver's expected props
(`work-index-cfg`, `tuning-func-cfg`, `cpudvfs-clusters`, `cluster-devices`,
`map-tbl-regs`, `dcdc-supply-mode-cfg`, `sprd,syscon-ang`, ...) are **absent** from
stock. The DT that matches our ported driver is the RP2+ kernel's
**`arch/arm64/boot/dts/sprd/sharkl5Pro-haps.dtsi`** (`cpudvfs-dev@322a8000` at
line ~389, `topdvfsctrl@322a0000` at ~335). The HAPS node's register offsets and
`*-dvfs-tbl` index tables are **SoC-fixed** (HW mux/div/voltage-grade encodings,
same on FPGA and silicon), so they are correct for our T618. Only the freq/volt
OPP numbers (in the per-CPU `cpufreq-data-v1` node) are emulation-specific and must
be replaced with real T618 values.

Into `ums512.dtsi` (+ enable in board dts), replacing the abandoned
`sprd,cpufreq-v2` node + `performance-domains`/`#performance-domain-cells`:

- Transcribe `topdvfsctrl@322a0000` (`sprd,sharkl5pro-topdvfs`, `syscon`) and
  `cpudvfs-dev@322a8000` (`sprd,sharkl5pro-cpudvfs`) **verbatim** from
  `sharkl5Pro-haps.dtsi`, including all phandle-referenced sub-nodes: `mpll-cells`
  (`mpll_0/1/2`), `apcpu-dvfs-dcdc-cells` (`apcpu_cpu0/1`), `cpudvfs-clusters`
  (`lit_core_cluster`/`big_core_cluster` with their `*-dvfs-tbl`, `map-tbl-regs`,
  `cluster-devices` `sel/div/vol-get`), and the `dcdc-*` supply-mode nodes.
- Wire syscon phandles to our tree's nodes: `sprd,syscon-enable`→`aon_apb_regs`,
  `mpll`/`sprd,syscon-ang`→the anlg phy/`pmu`/aon syscons (resolve names against
  `ums512.dtsi`). `dvfs-blk-dcdc-sd` is optional (guarded by IS_ERR) — can omit
  first pass.
- Per-CPU `cpufreq-data-v1` phandle → a data node with **real T618**
  `operating-points` (kHz µV) + `dvfs_bin` nvmem (`cluster0/1_dvfs_bin` already
  present). Real OPP values: cross-source from `dtb_stock` cpufreq-data nodes and
  the vendor `ums512-mach.dtsi` cluster tables (T618 tops ~2.0 GHz big / ~1.8 GHz
  little). HAPS/zebu operating-points are emulation freqs — do NOT use.
- Binning: the per-bin `operating-points-N` selection uses the `dvfs_bin` efuse
  (see `sprd_cpufreq_bin_main` in common.c) — provide at least the base table;
  add bin variants if real values are available.

## Bring-up / test

Build `boot_a` (Image, driver is built-in) — DTB lives in `vendor_boot`. After
flash, expect: `sprd-cpudvfs` probe → `sprd-hardware-cpufreq` registers →
`/sys/devices/system/cpu/cpufreq/policy0` + `policy6` appear with the T618 OPP
tables; `scaling_available_frequencies` populated; schedutil scales. Then wire the
thermal cooling maps (cpufreq cooling device now exists) to close out the thermal
trips that are currently inert.

## DT bring-up STATUS (done — 2026-06-27)

DT transcription complete and compiling (`ums512-1h10.dtb` + `ums512-infinix` both
clean). Changes:
- `ums512.dtsi`: replaced the dead-end `sprd,cpufreq-v2` node with the real-silicon
  `cpufreq-clus0/1` + scu/periph/gic OPP data nodes; swapped per-CPU
  `performance-domains` → `cpufreq-data-v1`; merged the `topdvfs_controller` identity
  into the existing `top_dvfs_apb_regs: syscon@322a0000` (same address — can't
  duplicate); added `cpudvfs-dev@322a8000` (5 clusters + mpll + apcpu),
  `status="disabled"` by default. mpll syscon-ang → `anlg_phy_g2/g3_regs` (exist).
- `ums512-1h10.dts`: added the two `dvfs_dcdc_cpuN_supply` voltage-grade nodes, wired
  `dcdc-supply-mode-cfg` via `&dcdc_cpu0/1` label overrides (board-specific PMIC), and
  `&cpudvfs_dev { status = "okay"; }`.
- Omitted (optional, IS_ERR-guarded / absent macros): the `dvfs-blk-dcdc-sd` PMU
  syscons (need `REG/MASK_PMU_APB_RF_DVFS_BLOCK_SHUTDOWN_*` macros not in our headers).

## BUILD STATUS (done — 2026-06-27)

Kernel + DTBs build clean (exit 0). The cpufreq stack is built into the Image
(`sprd-cpufreqhw.o`, `sprd-hwdvfs-normal.o`, `sprd-cpufreq-common.o`,
`sprd-sysfs-normal.o`, `sprd-hwdvfs-archdata.o` — all five wired via
`CONFIG_ARM_SPRD_CPUFREQ_HW=y`, also added to `ums512_defconfig` +
`ums512-uboot_defconfig`). Repacked `build/boot/boot_custom.img` (new Image +
initramfs) and `build/boot/vendor_boot_custom.img` (new DTB, dtb size 52889).

## ON-DEVICE STATUS (working — 2026-06-27)

Flashed `boot_a` + `vendor_boot_a`. `sprd-cpudvfs` probes, `sprd-hardware-cpufreq`
registers, and **both** policies come up correctly:
- `policy0` → cpu 0–5 (A55), table 614.4 MHz → 1.82 GHz.
- `policy6` → cpu 6–7 (A75), table 1.2288 → 2.002 GHz.
schedutil attached; `affected_cpus` split 0-5 / 6-7.

**Topology fix (4.14→6.16 delta, the load-bearing one):** the driver equated the
HW DVFS cluster id with `topology_physical_package_id()` / used `cpu_coregroup_mask()`
for the policy mask. On 4.14 the cpu-map `cluster` nodes set `physical_package_id`;
since ~5.16 they set `cluster_id` (package_id stays 0 with no `socket` level), so
*all 8 CPUs* landed in one policy driven by cluster0's table. Swapped every site to
`topology_cluster_id()` / `topology_cluster_cpumask()` (sprd-cpufreq-common.h macros
`sprd_cpufreq_data`/`is_big_cluster` + 6 direct sites in cpufreqhw.c/common.c).
Verified against device sysfs: cpu0 cluster_id=0, cpu6 cluster_id=1,
cluster_cpus_list 0-5 / 6-7.

**Benign noise (do not chase):** `can not get dvfs_bin ret -2` (efuse nvmem cell
not wired → falls back to base/un-binned OPP table, conservative & safe) and the
`dev_pm_opp_remove: Couldn't find OPP …` churn at probe (init ordering; the
surviving per-cluster tables are the full correct T618 sets).

## THERMAL THROTTLING (done — 2026-06-27)

Closed out the inert thermal trips. The cpufreq driver now sets
`CPUFREQ_IS_COOLING_DEV` (`sprd-cpufreqhw.c`), so the cpufreq core auto-registers a
cooling device per policy: `/sys/class/thermal/cooling_device0 = cpufreq-cpu0`,
`cooling_device1 = cpufreq-cpu6`. The `ums512.dtsi` thermal-zone `cooling-maps` were
rewritten to reference the policy-leader CPUs only (`&CPU0` for all little-cluster
zones, `&CPU6` for big) — `of_cpufreq_cooling_register()` registers one cooling
device per policy bound to the leading CPU's node, and all cores in a policy share a
clock so throttling the leader throttles the cluster. Verified on-device: zones bind
their cdevs; 70 °C passive trips cap frequency, 110 °C critical trip = shutdown
backstop. `No trip points found for thermal id=0` is benign (trip-less gpu/gpuank2
monitor-only zones).

**Optional later:** wire the `dvfs_bin` nvmem cell for per-chip voltage binning (the
`can not get dvfs_bin ret -2` fallback; base table is safe meanwhile).

## Risks / open questions

- The 4.14→6.16 jump is the main risk, but the engine's lack of clk/timer/thread/
  thermal use makes it mostly mechanical.
- **RESOLVED — i2c DCDC:** the big cluster (CPU1) drives its "third PMIC" via the
  SoC **top-dvfs hardware i2c master** (`chnl-in-i2c=1` + `top-dvfs-i2c-state`), NOT a
  Linux i2c bus. At runtime `sprd_cpudvfs_set_target` uses the i2c_client *only* to
  lock the bus, guarded by `if (i2c_used && i2c_client)`. Stock leaves `aon_i2c0`
  disabled with no FAN53555 node, so we need **no** `REGULATOR_FAN53555` / aon_i2c0 /
  virtual-i2c device — `i2c_client` stays NULL and big-cluster DVFS still works. CPU0
  (little) is internal (`chnl-in-i2c=0`, `top-dvfs-adi-state`).
- `dcdc_voltage_grade_parse()` requires the supply node (`dcdc-supply-mode-cfg`) —
  mandatory, not optional; its voltage-grade tables come from the 4-14 `ums512-1h10`.
