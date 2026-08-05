# eFuse shadow, thermal trim, and CPU DVFS binning (UMS512 / T618)

Status: **FIXED** on the Android/GammaOS side as of 2026-08-04 — one line in
[`ums512_1h10.open.config`](../src/spl/board/ums512_1h10.open.config). Mainline turned out never to
have been affected by this bug at all, though investigating it did uncover a separate and serious
thermal defect there, now fixed; see [Open items](#open-items).

One useful side effect of the SPL fix: the eFuse RAM shadow is now trustworthy at kernel runtime.
Read live at phys `0x15C00` (status word 0 = success, data at `0x15C04`, 24 blocks = 0x60 bytes),
it is **byte-for-byte identical** to the direct `ap_efuse@32240000` reads mainline already uses. So
there is no reason to switch mainline back to the shadow — the data is the same and the direct read
has no bootloader dependency.

## TL;DR

`CONFIG_SPL_FW_SEG7` in our SPL corrupts the eFuse RAM shadow. That single region carries **both**
the thermal sensor trim **and** the CPU DVFS voltage binning, so corrupting it produces two
apparently unrelated user-visible faults at once:

- **"Degraded performance"** — the die reads ~45 °C too high, which is past the 70 °C passive trip,
  so the thermal governor pins every cluster to its frequency floor permanently. Measured at idle:
  `policy0` capped to 614400 against a 2002000 ceiling, a **3.3× loss**. Separately, garbage
  `dvfs_bin` makes `sprd-cpufreq` fail to register a policy for cpu0–5 **at all**.
- **"Random reboots"** — under load the same false offset carries the reading past the 110 °C
  critical trip, which hard-resets the device. The SoC is not actually that hot.

**The fix:** keep `CONFIG_SPL_FW_PARITY`, drop `CONFIG_SPL_FW_SEG7`. Both flags are needed in
combination — neither alone is correct.

## The shared region

The device tree node `efuse@800` (`sprd,ums512-cache-efuse`) is a **RAM shadow** of the fuses, not
the fuse controller. The SPL fills it: `sprd_write_efuse_to_ram()`
([`drivers/efuse/efuse.c`](../src/spl/chipram/drivers/efuse/efuse.c)) stages efuse blocks 72..95
into IRAM, called from `Chip_Init()` after `sdram_init()`.

Addressing, which is confusing enough to be worth stating plainly: the IRAM aperture is based at
`0x15400`, so the DT offset `0x800` lands at `0x15C00` (the read-status word), and the block data
starts at `0x15C04`.

Cells the kernel consumes from it:

| cells | consumer |
|---|---|
| `thm0/1/2-{sen,ratio,sign}` | thermal sensor trim (all on-die zones) |
| `dvfs-bin@13/@17/@1b`, `cpu-flag@50` | CPU voltage-grade binning (`sprd-cpufreq`) |
| `uid-start/end` | chip UID |

This is why one bug shows up as two symptoms, and why "thermal" and "performance" reports from users
are likely the *same* issue.

## Are you affected?

Quick checks on a running Android userdebug build:

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

Broken (as shipped, SEG7 on) looked like: `ank1` 36 °C next to `ank5` 90 °C on the same die, no
`policy0`, and `soc-thmzone` climbing 77 → 106 °C under load with cooling already pinned at 5/5 and
no regulation happening at all.

## The fix, and why both flags matter

| `FW_PARITY` | `FW_SEG7` | cpu0–5 policy | die vs board | verdict |
|---|---|---|---|---|
| on | on *(as shipped)* | **absent** | 36–91 °C, incoherent | broken |
| off | off | present | +45 °C uniform | broken |
| **on** | **off** | **present** | **+5…+7 °C** | **matches stock** |

`FW_PARITY` is *required* — without it every sensor sits ~45 °C high. `FW_SEG7` is *harmful* — it
breaks `dvfs_bin` outright and scrambles per-sensor trim. Turning both off (the intuitive "revert
the recent changes" move) is **not** a fix; it produces a third, different broken state.

`FW_SEG7` is `mem_top_catchall_sec()`, the PUB seg7 above-DRAM catch-all reprogrammed on every boot,
in [`firewall_sharkl5pro.c`](../src/spl/chipram/secure/trustzone/firewall_sharkl5pro.c).

**Why seg7 damages the shadow is not understood.** The evidence is behavioural — flip the flag, the
symptom flips — not mechanistic. If seg7 was guarding something real, dropping it may reintroduce
whatever that was. Re-test against the table above rather than assuming.

Validated under sustained 8-way CPU load: idle 56.6 °C at 2002000/2002000, load peaks 94.6 °C,
throttling engages progressively and **regulates back down to 83.7 °C**, no reboot.

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
adb reboot
```

Two measurement rules worth internalising:

1. **`board-thmzone` is the untrimmed reference.** It is an ADC/NTC sensor with no efuse dependency,
   so it is ground truth for how far off the die sensors are.
2. **To distinguish a calibration offset from real heat, use a cooldown curve — not a board-vs-die
   delta.** A 50–60 °C die-to-board delta is perfectly legitimate for an unthrottled SoC, so that
   argument proves nothing on its own. Idle the device and watch instead: real heat decays, a trim
   offset does not. In the broken state `soc` sat flat at 90.05 °C to within one ADC LSB across five
   minutes at minimum frequency, while board held ~45 °C.

## Traps

- **The diag build's `.bss` overlaps the efuse shadow.** `CONFIG_SPL_EMMC_TRACE`'s 2 KB static
  buffer pushes `.bss` to `0x15F00` — 768 bytes into the `0x15C00–0x15FFF` window. Production
  (`signed-open`) ends at `0x14DB8` and is clear. During this investigation an efuse capture buffer
  landed *inside the window it was capturing* and produced a completely convincing, deterministic,
  reproducible — and entirely fabricated — "3 corrupted words" result that sent the hunt in the
  wrong direction for some time. **Check `nm` / the link map before trusting any in-SPL capture of
  this region.**
- **SPL builds are non-deterministic at the signing/packing step.** Identical source yields
  different `.img` bytes but an identical payload. Compare
  `out/<variant>/nand_spl/u-boot-spl-16k.bin`, never the packed image hash. A rebuild is
  functionally equivalent but not byte-identical, so keep a real backup image for exact rollback.
- **`build.sh` uses `make -j$(nproc)` and has a header race** that fails the `fdl1` target with a
  misleading `#error pls don't change PACKET_MAX_NUM or MAX_PKT_SIZE`. Force a serial build; it is
  not your code.
- **Android's dmesg ring is full by ~5.2 s of uptime** (~11k lines), so thermal-zone and
  cpufreq-policy registration have already scrolled off even a minute after boot. Use `log_buf_len=`
  or pstore if you need them.
- `/dev/mem` and `/proc/last_kmsg` do not exist on this build, and `/sys/fs/pstore/` is empty
  because a critical-trip reset leaves no console-ramoops. Read state via `/proc/device-tree` and
  sysfs.

## Ruled out

- **Memory corruption is unrelated.** The widevine carve-out is verified in place —
  `e3800000-f2ffffff : reserved` in `/proc/iomem`. Note that presence in `/proc/device-tree` proves
  nothing for a reservation: that reflects the tree *after* overlays are applied, while
  `fdt_scan_reserved_mem()` runs before them. Always confirm via `/proc/iomem` or memblock.
- **`CONFIG_SPL_DRAM_SCRUB`** is never defined anywhere in the tree (only its two `#ifdef` sites)
  and is absent from the built binary. It also only touches DRAM at `0x94000000`, nowhere near IRAM.
- **The firewall `IRAM_EFUSE_ADDR` guard is not the fix.** It is kept because `0x15C00` is the
  region actually in use and stock's `0x800` protects nothing — but `iram_sec()` runs from
  `sprd_firewall_config()` at the very end of the SPL, so it can only ever protect *post*-SPL
  stages, never an in-SPL write.

## Open items

- ~~**Revisit the mainline idle-injection workaround.**~~ **Answered 2026-08-04: mainline was never
  affected by this bug, and the idle injection was not too aggressive — it was reaching one core.**
  - Mainline thermal *trim* is immune (moved to `ap_efuse@32240000`), and mainline ums512 has **no
    `dvfs_bin` cell at all** — only `ums9230.dtsi` defines one. The boot warning
    `sprd_cpufreq: can not get dvfs_bin ret -2` is expected and benign. So the two symptoms are
    **not** the same bug.
  - Do **not** add the `dvfs_bin` cells to mainline. `sprd_cpufreq_bin_main()` returning a valid
    bin makes `sprd-cpufreq-common.c` build the OPP property name `operating-points-<bin>`; our DT
    only has plain `operating-points`, so it would fail `-ENODATA` and cpufreq would stop
    registering entirely. Binning only selects a *table name* — we already have the one correct
    stock T618 table — so it cannot affect whether the clock moves.
  - The real defect was elsewhere: the single `thermal-idle` node under `CPU0` throttled **one core
    of eight**, because psci registers one cpuidle driver per cpu
    (`cpuidle-psci.c: drv->cpumask = cpumask_of(cpu)`). Fixed by giving every cpu its own node.
    Sustained 8-way load went from "101 °C and still climbing" to a steady 70–71 °C.
  - CPU DVFS on mainline **is** genuinely inert, independently of any efuse issue. Measured with
    the PMU cycle counter against a pinned busy loop: cluster0 sits at a fixed **1536 MHz** and
    cluster1 at **1228.8 MHz** (its table *floor*) regardless of what is requested. Note the hw
    *does* latch the index and move the voltage grade — the clock just never follows. Root cause
    still unknown; this is the next thing worth chasing, since the A75s being pinned at their floor
    is a ~1.63× performance loss and idle injection saves power only linearly where DVFS saves
    ~V²f.
  - Measurement trap: `scaling_cur_freq` and the `sprd_hwdvfs_normal: Get cpu frequency-indexN`
    dmesg line both just echo the latched index and will happily report a frequency the silicon is
    not running. Use `perf stat -e armv8_cortex_a55/cycles/ -C <cpu>` against a pinned load.
    Also beware `boost_mode_flag` (static init 1) in `sprd-cpufreqhw.c`: `target_index` returns 0
    without doing anything while it is set and `policy->max >= cpuinfo.max_freq`.
- **Understand why seg7 corrupts the shadow.** Currently behavioural evidence only.
- **Fix the diag `.bss` overlap** (explicit section placement, or shrink the trace buffer) and add a
  build-time assert that `.bss` ends below `0x15C00`, so in-SPL captures of this region can be
  trusted again.
