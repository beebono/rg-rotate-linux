# eFuse shadow, thermal trim, and CPU DVFS binning (UMS512 / T618)

Status: **FIXED** on the Android/GammaOS side as of 2026-08-05, in SPL commit `4266a73` — the eFuse
RAM shadow was being staged at the wrong address. Mainline was never affected (it reads the fuses
directly), though investigating this did uncover a separate and serious thermal defect there, now
fixed; see [Open items](#open-items).

> **An earlier version of this document blamed `CONFIG_SPL_FW_SEG7` and carried a `FW_PARITY` ×
> `FW_SEG7` truth table. That conclusion is retracted** — see
> [Retraction](#retraction-the-parity--seg7-truth-table). The flags were never involved. If you are
> here because you remember "turn SEG7 off", that advice was wrong and has been reversed.

## TL;DR

`sprd_write_efuse_to_ram()` staged the eFuse RAM shadow at **`0x15c04`**. This SoC's kernel reads it
at **`0x800`**. So the SPL read the fuses correctly, wrote a correct shadow to a location nothing
reads, and the kernel consumed whatever garbage happened to be sitting at `0x800`.

That single region carries **both** the thermal sensor trim **and** the CPU DVFS voltage binning, so
one wrong constant produced two apparently unrelated user-visible faults at once:

- **"Degraded performance"** — the die reads ~45 °C too high, past the 70 °C passive trip, so the
  thermal governor pins every cluster to its frequency floor permanently. Measured at idle:
  `policy0` capped to 614400 against a 2002000 ceiling, a **3.3× loss**. Separately, garbage
  `dvfs_bin` makes `sprd-cpufreq` fail to register a policy for cpu0–5 **at all**.
- **"Random reboots"** — under load the same false offset carries the reading past the 110 °C
  critical trip, which hard-resets the device. The SoC is not actually that hot.

**The fix:** stage at `0x800`/`0x804` in
[`drivers/efuse/efuse.c`](../src/spl/chipram/drivers/efuse/efuse.c). No board-config flag changes
are involved.

## The shared region

The device tree node `efuse@800` (`sprd,ums512-cache-efuse`) is a **RAM shadow** of the fuses, not
the fuse controller. The SPL fills it: `sprd_write_efuse_to_ram()` stages efuse blocks 72..95 into
IRAM, called from `Chip_Init()` after `sdram_init()`.

**Addressing — the thing that was wrong.** `efuse@800` is a **root-level node with an absolute
address**. There is no IRAM aperture to add to it:

```dts
efuse@800 {
    compatible = "sprd,ums312-cache-efuse\0sprd,ums512-cache-efuse";
    reg = <0x00 0x800 0x00 0x3ff>;
    thm0-sen0@39 { reg = <0x39 0x01>; };    /* offsets into the shadow */
    dvfs-bin@13  { reg = <0x13 0x01>; };
};
```

So the status word is at `0x800` and block data at `0x804`. The stock SPL agrees — its staging
routine is the same algorithm as ours at the correct address:

```
8904:  mov  x0, #0x804          ; staging base
8924:  str  wzr, [x0], #4       ; zero-fill
8928:  cmp  x0, #0x864          ; 24 words
8930:  mov  w1, #0x5f           ; end_id 95
8934:  mov  w0, #0x48           ; start_id 72
8940:  bl   0xac60              ; efuse_read_drv(72, 95, buf, 0)
898c:  mov  x0, #0x800          ; status word
```

Cells the kernel consumes from it:

| cells | consumer |
|---|---|
| `thm0/1/2-{sen,ratio,sign}` | thermal sensor trim (all on-die zones) |
| `dvfs-bin@13/@17/@1b`, `cpu-flag@50` | CPU voltage-grade binning (`sprd-cpufreq`) |
| `uid-start/end` | chip UID |

This is why one bug shows up as two symptoms, and why "thermal" and "performance" reports from users
are likely the *same* issue.

## Are you affected?

Quick checks on a running Android userdebug build, **from a cold boot** (see
[Traps](#traps) — a warm reboot measures the previous image):

```sh
# 1. Do all on-die sensors agree? They should be within a few degrees of each other.
for z in /sys/class/thermal/thermal_zone*; do \
    printf "%-22s %s\n" "$(cat $z/type)" "$(cat $z/temp)"; done

# 2. Does the little cluster have a cpufreq policy at all?
ls /sys/devices/system/cpu/cpufreq/          # want: policy0 AND policy6

# 3. Are the clusters being held below their ceiling?
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq   # want 2002000
cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq

# 4. The single clearest tell in dmesg:
dmesg | grep sprd_cpufreq_cooling
#   broken : "cpu6 temp: 0 update max_freq to 1742000"
#   healthy: "cpu0 change dvfs table and update max_freq to 2002000"
```

Healthy looks like: every on-die zone within a few degrees, `board-thmzone` some 5–10 °C below them,
both policies present and uncapped.

Two distinct broken shapes, worth telling apart because they have different causes:

- **Uniform offset** — every zone ~45 °C above board, flat, no decay at idle. Consistent with the
  shadow being all-zero (the read failed and `write_efuse_to_ram()`'s unconditional zero-fill
  survived), giving every sensor the same null calibration.
- **Incoherent scatter** — e.g. `ank2` at 42.6 °C beside `soc` at 100.7 °C on the same die at the
  same instant. The shadow contains plausible-looking but wrong per-sensor values.

Both were observed while the staging address was wrong.

## Verified fix

Cold boot on ums512 (ROTATE03750549), before → after:

| | before | after |
|---|---|---|
| policies | `policy6` only | `policy0` + `policy6`, both 2002000 |
| zones | 42.4 – 101.2 °C, incoherent | 52.9 – 55.8 °C, board 48.2 |
| idle curve | flat at ~+45 °C, no decay | decays 51.9 → 50.0 °C (**+4.1 °C**) |

Matching the patched-stock oracle (+4.8 °C settled) on the same device.

## Retraction: the PARITY × SEG7 truth table

This document previously carried a table concluding that `FW_SEG7` corrupted the shadow and had to
be turned off, and that `FW_PARITY` was required. **Both halves were artifacts.** Two errors
combined to produce a table that looked convincing and reproduced on demand:

1. **The shadow was mis-addressed regardless of any firewall flag**, so every cell of the table was
   measuring the same broken staging. The flags could not have mattered.
2. **The rows were measured across warm reboots.** IRAM survives warm reset, so a boot that followed
   a stock boot inherited stock's good shadow at `0x800` — while our SPL wrote `0x15c04` and never
   overwrote it. The "+5…+7 °C, matches stock" row *was stock's own data*, read back through our
   SPL.

Proved with one binary and two boot types — identical flashed image, no power cycle in between:

| boot | policy0 | soc | board |
|---|---|---|---|
| cold | absent | 90.3 °C | 46.0 °C |
| warm, immediately after a patched-stock boot | present | 56.9 °C | 49.1 °C |

`FW_SEG7` additionally **could not have corrupted anything, because it never executed.**
`mem_top_catchall_sec()` derived the DRAM size from `chipram_env->dram_size`, which
`chipram_env_set()` zeroes and nothing ever fills in, so it always tripped its own `>= 2 GB` sanity
guard and returned. It now reads `cs_number`/`cs0_size`/`cs1_size` like stock, and is **enabled** in
both board configs — stock programs PUB seg7 (`0x3280c380`) on every boot, and without it accesses
above top-of-DRAM alias back into real memory instead of faulting.

## How to verify a change

**Use the stock SPL as the oracle.** Black-box A/B against stock is far more trustworthy here than
in-SPL instrumentation (see [Traps](#traps)), and it takes about two minutes per flip:

```sh
# Patch stock so it will boot a non-stock u-boot (NOPs the 4 RSA image checks)
python3 src/spl/scripts/patch_stock_spl.py \
        device/stock/fw/extracted/spl_a.img /tmp/spl_stock_patched.img

# The SPL lives in the eMMC BOOT partitions - there is no spl/splloader GPT entry.
# Both are 4 MiB and hold the same image; force_ro is already 0 on this device.
adb push /tmp/spl_stock_patched.img /data/local/tmp/s.img
adb shell su -c "dd if=/data/local/tmp/s.img of=/dev/block/mmcblk0boot0 bs=1M; \
                 dd if=/data/local/tmp/s.img of=/dev/block/mmcblk0boot1 bs=1M; sync"
# then POWER DOWN and cold boot - see the A/B rule below
```

Three measurement rules worth internalising:

1. **A/B an SPL from cold boots only.** IRAM and the TZPC/mem-firewall block both survive warm
   reset, so `adb reboot` measures a mixture of the new image and whatever the previous one left
   behind. This single mistake produced the retracted truth table above. A warm reboot *is* a useful
   tool — it isolates the SPL binary as the only variable, since DRAM/IRAM/ambient are held constant
   — but only when you already know what the previous image left.
2. **`board-thmzone` is the untrimmed reference.** It is an ADC/NTC sensor with no efuse dependency,
   so it is ground truth for how far off the die sensors are.
3. **To distinguish a calibration offset from real heat, use a cooldown curve — not a board-vs-die
   delta.** A 50–60 °C die-to-board delta is perfectly legitimate for an unthrottled SoC, so that
   argument proves nothing on its own. Idle the device and watch instead: real heat decays, a trim
   offset does not. In the broken state `soc` sat flat at 83.8–86.4 °C across 2.4 minutes on a
   physically room-temperature device while `board` drifted *up* 38.5 → 40.9 °C.

## Traps

- **A warm reboot measures the previous SPL.** See rule 1 above. This is the single most expensive
  trap in this file.
- **SPL builds are non-deterministic at the signing/packing step.** Identical source yields
  different `.img` bytes but an identical payload. Compare
  `out/<variant>/nand_spl/u-boot-spl-16k.bin`, never the packed image hash. A rebuild is
  functionally equivalent but not byte-identical, so keep a real backup image for exact rollback.
- **A flag can be compiled in and still never run.** `CONFIG_SPL_FW_SEG7` changed the payload hash
  while `mem_top_catchall_sec()` returned at its first guard on every boot, so flag-flipping
  "experiments" were comparing two identical behaviours. Before trusting an A/B, confirm the code
  under test actually executes.
- **The diag build's `.bss` used to overlap what we thought was the shadow.**
  `CONFIG_SPL_EMMC_TRACE`'s 2 KB static buffer pushes `.bss` to `0x15F00`. That mattered only while
  the shadow was believed to live at `0x15C00`; now that it is at `0x800`, there is no collision and
  the trace build is usable for capturing this region. Historical note: a capture buffer once landed
  *inside the window it was capturing* and produced a completely convincing, deterministic,
  reproducible — and entirely fabricated — "3 corrupted words" result.
- **`build.sh` uses `make -j$(nproc)` and has a header race** that fails the `fdl1` target with a
  misleading `#error pls don't change PACKET_MAX_NUM or MAX_PKT_SIZE`. It does not affect the SPL
  payload; it is not your code.
- **Android's dmesg ring is full by ~5.2 s of uptime** (~11k lines), so thermal-zone and
  cpufreq-policy registration have already scrolled off even a minute after boot. Use `log_buf_len=`
  or pstore if you need them.
- `/dev/mem` and `/proc/last_kmsg` do not exist on this build, and `/sys/fs/pstore/` is empty
  because a critical-trip reset leaves no console-ramoops. Read state via `/proc/device-tree` and
  sysfs.
- **The `sprd-cache-efuse` / `sprd-efuse` nvmem sysfs on GammaOS returns unstable garbage** —
  consecutive reads of the same device return different bytes, with `c0 ff ff ff` filler and
  pointer-shaped values. Do not use it to inspect the shadow; read the temperatures instead, whose
  shape is a reliable proxy.

## Ruled out

- **Memory corruption is unrelated.** The widevine carve-out is verified in place —
  `e3800000-f2ffffff : reserved` in `/proc/iomem`. Note that presence in `/proc/device-tree` proves
  nothing for a reservation: that reflects the tree *after* overlays are applied, while
  `fdt_scan_reserved_mem()` runs before them. Always confirm via `/proc/iomem` or memblock.
- **`CONFIG_SPL_DRAM_SCRUB`** is never defined anywhere in the tree (only its two `#ifdef` sites)
  and is absent from the built binary. It also only touches DRAM at `0x94000000`, nowhere near IRAM.
- **`REG_AON_SEC_APB_SECURE_EFUSE_BOUNDRY`** (`AON_SEC_APB + 0x20`) is *not* involved, despite the
  suggestive coincidence that the kernel's `SPRD_EFUSE_NORMAL_BLOCK_OFFSET` is 72 and we read blocks
  72..95 through the secure aperture. It is declared in every SoC's `aon_sec_apb.h` and written by
  **no `.c` file in the tree** — and a static scan of the stock SPL shows stock never writes it
  either. Writing it does perturb the staged data, so it is live; it is simply not the bug.
- **The firewall `IRAM_EFUSE_ADDR` guard is not the fix.** It now points at `0x800` (the region
  actually in use, matching stock's `first/last = 0x80/0xbf`), but `iram_sec()` runs from
  `sprd_firewall_config()` at the very end of the SPL, so it can only ever protect *post*-SPL
  stages, never an in-SPL write.

## Open items

- **Mainline CPU DVFS is inert — root cause unknown. This is the main open thread.** The hardware
  latches the work index and moves the voltage grade, but the clock never follows. PMU-measured
  against a pinned busy loop: cluster0 fixed at **1536 MHz**, cluster1 at **1228.8 MHz** (its table
  *floor*, a ~1.63× loss) regardless of what is requested.
  - Narrowed to hardware/pre-Linux state. Driving the work-index register by hand
    (`devmem 0x322a8214`, kernel entirely out of the loop) moves `VOLT_DBG` (`0x322a8030`) on every
    write while `CGM_CFG_DBG0` (`0x322a8038`) stays bit-frozen at `0x02110842`. That clears the
    whole kernel-side category — driver, governor, OPP tables, binning, DT map tables.
  - ~~`MPLL_INDEX_READ` (`0x322a82d0`) = `0x00032C30`: **MPLL1** (prometheus/big) is **powered
    down** (`PD=1`, `CLKOUT_EN=0`)~~ — **wrong, misdecoded; corrected 2026-08-05.** Set bits in
    `0x00032C30` are 4,5 / 10,11,13 / 16,17, and per `apcpu_dvfs_apb.h` (`MPLLn_INDEX`
    [2:0]/[8:6]/[14:12], `_DVFS_PD` bit 3/9/15, `_DVFS_CLKOUT_EN` bit 4/10/16, `_CNT_DONE` bit
    5/11/17) that means **all three MPLLs have `PD=0`, `CLKOUT_EN=1`, `CNT_DONE=1`** — alive,
    locked and outputting (MPLL0 index 0, MPLL1 index 0, MPLL2 index 2). The MPLL gates at
    `0x327e0190/194/198` also all read `0x1`. Nothing is powered down; the state machine simply
    never advances any index for any MPLL, and the mux stays at `sel` 2, never 3.
  - ~~**Next step:** read `CGM_CFG_DBG0` / `MPLL_INDEX_READ` under stock Android as an A/B
    oracle~~ — **done 2026-08-05, answered by PMU instead.** Stock (GammaOS, Balanced mode) scales
    perfectly on this exact silicon: every OPP tracks its request within 0.2%, A55 0.613→2.001 GHz
    and A75 1.229→2.002 GHz, measured with `simpleperf stat -e cpu-cycles` against a pinned
    spinner. So the hardware works and this is ours to fix. (Benchmarking trap: GammaOS's default
    *Max Performance* mode pins both clusters at 2002000 under the `userspace` governor with
    nothing driving it, and swallows `scaling_setspeed` — switch the OS to **Balanced** first.
    Register-level A/B on stock is blocked for good: `CONFIG_DEVMEM is not set`, and regmap
    debugfs only covers `0-0x7ffc` while our registers are at `0x322a8000+`.)
  - **The one remaining symptom:** writing the work index does not start the frequency-update state
    machine. Sampled continuously at sub-µs cadence across a real `driver->set`,
    `MPLL_DVFS_STATE` (`0x322a82a0`) and `APCPU_FREQ_UPDATE_STATE0` (`0x322a82a4`) never leave `0`.
    Meanwhile the big cluster's work index (`0x322a8224`) tracks correctly (1→2→4→6) and
    `VOLT_DBG` changes every time — index and voltage arms work, the clock arm never triggers.
  - **Next step — start with stock's *policy* module, then port.** Stock splits arch
    (`sprd-hwdvfs-normal.c` + `sprd-hwdvfs-ums512.c`) from policy (`sprd-hwdvfs-cpufreq.c`), and
    the arch half exposes only a **7-entry** ops table — the policy layer sequences work at
    runtime. Our port front-loads everything into probe behind a **23-entry** table with no runtime
    sequencing, so if the trigger is a policy-layer call we never make, poking the arch half will
    never find it. Read `vendor/android-kernel-5-4-realme/drivers/cpufreq/sprd-hwdvfs-cpufreq.c`
    (its `target_index` and cluster-enable paths) and diff the call sequence against our
    `sprd-cpufreqhw.c` first — that may be a small fix with no port. Otherwise do the bringover:
    ~3,850 lines, two self-contained modules, only `CPUFREQ_STICKY` and `cpufreq_generic_attr` are
    gone in 7.1; the DT node can be lifted from `docs/decomp_stock.dts`, which is a working
    reference for the 5.4 binding. Note `CONFIG_ARM_SPRD_CPUFREQ_HW` in the 5.4 tree builds
    `sprd-cpufreqhw.o` — i.e. exactly what we ported, which Unisoc superseded in the same tree.
  - Ruled out 2026-08-05: **init ordering** — reordered our per-MPLL init to match stock's
    `sprd_dvfs_device_init` (sel-switch before relock/pd, plus `udelay(50)`), commit `5357737`;
    built, booted, *zero* change. Also the MPLL gates (`0x327e0190/194/198`, all `0x1`),
    `clk_ignore_unused` (no effect), and a cpudvfs probe failure (probe succeeds cleanly).
    SPL is shared with Android, and stock u-boot's `apcpu_dvfs_init` was disassembled and is
    instruction-identical to ours, so the whole boot chain is eliminated.
  - Ruled out: SMC/SIP calls (they live in `sprd-cpufreq-v2.c`, a different driver that never probes
    here — stock also uses the `sprd,hardware-cpufreq` path); an interrupt mis-mapping (nothing in
    this path requests an IRQ, and neither stock nor mainline DT gives the cpudvfs/topdvfs nodes an
    `interrupts` property); `APCPU_FREQ_UPD_TYPE_CFG` delay bits and `APCPU_FREQ_UPDATE_BYPASS`
    (both poked live, no effect).
  - Measurement trap: `scaling_cur_freq` and the `sprd_hwdvfs_normal: Get cpu frequency-indexN`
    dmesg line both just echo the latched index and will happily report a frequency the silicon is
    not running. Use `perf stat -e armv8_cortex_a55/cycles/ -C <cpu>` against a pinned load. Also
    beware `boost_mode_flag` (static init 1) in `sprd-cpufreqhw.c`: `target_index` returns 0 without
    doing anything while it is set and `policy->max >= cpuinfo.max_freq`.
- **Re-test SEG7 in the scenario it exists for.** It executes for the first time as of `4266a73`,
  and has had exactly one cold boot plus a ROCKNIX boot (full `MemTotal`, no errors). The stale-
  segment problem it addresses is specifically described as biting *after Android has provisioned
  and shut down*, so that sequence has not actually been exercised yet.
- **Mainline's `cache_efuse@800` comment is now stale.** `ums512.dtsi` says the shadow is unusable
  because "our u-boot does not populate it" — it was populated, at the wrong address. Mainline reads
  `ap_efuse@32240000` directly and is unaffected either way, so this is a comment fix, not a
  behaviour change. The shadow is a viable source again if ever wanted.
- ~~**Understand why seg7 corrupts the shadow.**~~ Retracted — it does not, and never ran.
- ~~**Revisit the mainline idle-injection workaround.**~~ Answered 2026-08-04: mainline was never
  affected by the efuse bug, and the idle injection was not too aggressive — it was reaching one
  core. psci registers one cpuidle driver per cpu (`cpuidle-psci.c: drv->cpumask = cpumask_of(cpu)`),
  so the single `thermal-idle` node under `CPU0` throttled one core of eight. Fixed by giving every
  cpu its own node; sustained 8-way load went from "101 °C and still climbing" to a steady 70–71 °C.
  Do **not** add `dvfs_bin` cells to mainline: a valid bin makes `sprd-cpufreq-common.c` build the
  OPP property name `operating-points-<bin>`, which our DT does not have, so cpufreq would fail
  `-ENODATA` and stop registering entirely.
