# GPU bring-up: ARM Mali kbase (r54) on UMS512 / T618 (Mali-G52)

Goal: run the **ROCKNIX/Rockchip ARM `mali_kbase` DDK** (forked at `src/mali-kbase`,
branch `bifrost_port`) against the **UMS512 Mali-G52** GPU on the up-ported
`src/linux-7-1-sprd` kernel, driven by the **g29p1 Bifrost-G52 libmali** blobs in
`./blobs`, replacing the vendor `gondul`/`midgard` kbase trees.

## Why this is viable (compatibility ledger)

| Axis | Finding |
|---|---|
| GPU part | UMS512 = **Mali-G52 (TDVX, Bifrost)** — a **Job Manager** part. Same silicon family as RK356x, so the Rockchip Bifrost-G52 blob is ISA/command-stream compatible. |
| Blob | `libmali-bifrost-g52-g29p1-*.so` — embedded `arm_release_ver: g29p1-12eac0`, `1.5 Bifrost`, `atx_vulkan_jm` (JM path). `rk_so_ver: 4`. |
| UABI | JM `BASE_UK_VERSION` major = **11** across gondul (11.31), natt (11.36) and r54 (11.46). g29p1 sends major 11; r54 handshake matches and negotiates the minor **down** → handshake passes. Major stayed 11 the whole way, so no version wall. |
| Driver bind | r54 `of_device_id` includes `"arm,mali-bifrost"` (`mali_kbase_core_linux.c`). |

The scary failure case (blob refusing a major-version-mismatched kernel driver) does
**not** apply — see also [../MEMORY.md] and the survey in the port thread.

## What is already wired (verified in-tree)

DT side, target kernel `src/linux-7-1-sprd`:

- `ums512.dtsi` `gpu@60000000`: `compatible = "sprd,ums512-mali", "arm,mali-bifrost"`,
  correct `reg`, 3× IRQ (job/mmu/gpu on SPI 60), `power-domains = <&pmu GPU_TOP>`
  (genpd — no raw PMU register poking needed), `resets`, and
  `operating-points-v2 = <&gpu_opp_table>`.
- `gpu_opp_table` — **matches the vendor `sprd,dvfs-lists` exactly**:
  384 MHz @ 0.70 V, 512 @ 0.75, 614.4 @ 0.75, 768 @ 0.80, 850 @ 0.80.
- Board `ums512-rg-rotate.dts`: `&gpu { mali-supply = <&vddgpu>; status = "okay"; }`
  — `mali-supply` is exactly the name kbase looks up
  (`regulator_names[] = {"mali","shadercores"}` → `regulator_get(dev,"mali")`).

Driver side, `src/mali-kbase`:

- `MALI_PLATFORM_NAME` already defaults to **`devicetree`** (generic platform), so no
  SPRD-specific glue C is compiled — power on/off is standard
  `pm_runtime` + `clk_prepare_enable` + `regulator_enable`
  (`platform/devicetree/mali_kbase_runtime_pm.c`, already carries a pm_clk refcount
  race fix).

**Net: the DT authoring the port originally called for is essentially done.** The
generic devicetree platform + existing node cover power, clocks (enable), regulator,
genpd, IRQs, and the OPP table.

## The one real remaining gap: DVFS clock

The node lists `clocks = CLK_GPU_CORE_EB, CLK_GPU_MEM_EB, CLK_GPU_SYS_EB` (names
`gpu`/`mem`/`bus`). In `ums512-clk.c`:

- `CLK_GPU_CORE_EB` = `gpu_core_gate` — a **pure gate** (no `set_rate`).
- `CLK_GPU_CORE` = `gpu_core_clk` — the **composite** (mux over the TWPLL/LPLL/GPLL
  parents + divider). This is the only rate-settable GPU clock.

kbase devfreq scales via `dev_pm_opp_set_rate()` on the device's **first clock**. With
a gate at index 0, `clk_get_rate` reports (via parent propagation) but `set_rate` is a
no-op / fails → **frequency will not scale**. Voltage scaling via `mali-supply` is
fine (regulator is present).

## Phase plan

**P1 — fixed-frequency bring-up (do this first)**
- Build kbase with `CONFIG_MALI_DEVFREQ=n` (or DVFS off) so it never tries to
  `set_rate` the gate. GPU runs at whatever the composite was left at by clk-init.
- Success criteria: node probes, genpd powers GPU_TOP, clocks+regulator enable,
  `/dev/mali0` appears, **g29p1 blob handshake passes**, basic GLES/Vulkan render.

**P2 — DVFS**
- DT: make the OPP-managed clock the composite, e.g.
  `clocks = <&gpu_clk CLK_GPU_CORE>, <&gpu_clk CLK_GPU_CORE_EB>,
            <&gpu_clk CLK_GPU_MEM_EB>, <&gpu_clk CLK_GPU_SYS_EB>;`
  (index 0 = settable core; keep the EB gates so they're enabled too).
- Enable `CONFIG_MALI_DEVFREQ`; verify `set_rate` drives the mux+div across
  384–850 MHz and `mali-supply` tracks the OPP `opp-microvolt`.
- Confirm `gpu_core_clk`'s parent PLLs (TWPLL_384M/512M, LPLL_614M4, TWPLL_768M, GPLL)
  are selectable to hit each OPP; GPLL is the 850 MHz source.

## Open items / risks

- **ioctl minor back-compat**: handshake passing guarantees `VERSION_CHECK` only.
  r54 (minor 46) must still honor the older JM ioctl structs the g29p1 blob issues
  (~minor ≤31). Arm maintains minor back-compat within major 11; smoke-test first if
  rendering misbehaves. `natt` (r40 / 11.36) is a useful intermediate diff point.
- **MALI_USE_CSF must be 0** for the G52 JM build.
- Whether P1 even needs devfreq off depends on how the generic platform reacts to a
  non-settable clock[0]; if it tolerates it, P1 can keep the current DT unchanged.

## Applied patches (branch `bifrost_port`)

First `modprobe` on-device probed as `mali0` and correctly ID'd the G52
(arch 7.4.0 r1p0), then hit two issues. Resolution:

- **irq-names.patch — applied (cosmetic).** DT uses lowercase `job/mmu/gpu`;
  r54 tries uppercase first then falls back to lowercase (so IRQs already worked —
  the `-ENXIO: IRQ JOB not found` lines were just the failed first attempt logging).
  Patch reorders to lowercase-first → clean log.
- **runtime-pm.patch — applied (root-cause fix).** `kbase_device_runtime_init`
  used `pm_runtime_set_active`, so the first `get_sync` short-circuited and never
  called `regulator_enable`, while the first idle still `regulator_disable`d →
  "unbalanced disables for vddgpu" WARN. Switched to `pm_runtime_set_suspended`
  (genpd resume now enables the rail each cycle; also avoids a cold-boot SError if
  the GPU domain is off at probe). Also wires the DT `resets` phandle
  (assert/deassert on power-on) via a `soft_reset_callback`. Hunk #4 (the
  `resets_init()` call) was hand-applied — context drift from an extra
  `usage_count` else-if in this tree. `-DKBASE_PM_RUNTIME` in the Kbuild is
  redundant (already `#define`d in `backend/gpu/mali_kbase_pm_defs.h`) but harmless.
- **regulators.patch — NOT applied (superseded).** It masks the same warning by
  force-`enable` at probe / force-`disable` at term while keeping `set_active`.
  Applying it *together* with runtime-pm.patch would leave the enable count
  permanently at 1, pinning vddgpu on across every runtime-suspend (no power
  gating). runtime-pm.patch fixes the cause and preserves gating, so this one is
  left out.

## Userspace bring-up: GBM allocates from dma-heaps, not DRM

After the module probed clean, `glmark2-es2-drm` / `kmscube` failed at
`gbm_create_device()` ("Failed to create GBM device") on `/dev/dri/card0` — with
**no DRM allocation ioctl and no `/dev/mali0` open** in the strace. Root cause: the
g29p1 libmali GBM backend allocates buffers from **DMA-BUF heaps**, not DRM dumb
buffers. Blob strings: `/dev/dma_heap/system-uncached`, `/dev/dma_heap/%s`,
`/dev/dma_heap/protected`, `/dev/mali%u`.

The sprd DRM driver *does* support dumb buffers + PRIME import
(`sprd_gem_dumb_create`, `sprd_gem_prime_import_sg_table`), but the blob never uses
them — so that capability is irrelevant here.

Kernel gaps:
- `CONFIG_DMABUF_HEAPS` was **off** → `/dev/dma_heap/` didn't exist at all. Enabled
  `DMABUF_HEAPS` + `DMABUF_HEAPS_SYSTEM` + `DMABUF_HEAPS_CMA` in `ums512_defconfig`
  (CMA/DMA_CMA already on). **Requires a kernel rebuild + reflash.**
- Naming: mainline `system_heap.c` registers only `system` (+ `system_cc_shared`).
  The blob explicitly opens `system-uncached` (a Rockchip downstream heap). Mali on
  UMS512 is **non-coherent** (vendor `system-coherency=31`, mainline node has no
  `dma-coherent`), so uncached buffers matter for correctness, not just naming.

Test order after rebuild:
1. `ls /dev/dma_heap/` → expect `system`, `cma`.
2. Re-run `glmark2-es2-drm -d`. If GBM now inits, the blob fell back to `system`
   (accepting possible cache artifacts) — good enough to prove the pipeline.
3. If it still fails demanding `system-uncached`, add that heap: quick unblock =
   register the system heap under the extra name `system-uncached`; correct fix =
   backport an uncached/write-combine heap variant with begin/end-cpu-access cache
   maintenance (Rockchip-style), matching Mali's non-coherent access.

**RESULT — P1 COMPLETE (working).** With `DMABUF_HEAPS` enabled, `glmark2-es2-drm`
runs: `GL_VENDOR: ARM`, `GL_RENDERER: Mali-G52`, `GL_VERSION: OpenGL ES 3.2
v1.g29p1-12eac0`, ~100–120 FPS at 720x720. The blob used the **`system`** heap
(no `system-uncached` needed); texture tests pass, so coherency is OK via the
system heap's dma-map cache maintenance. Full chain proven: r54 kbase → g29p1 blob
handshake → dma-heap → GBM → sprd DRM scanout. Runtime notes: module sysfs name is
`bifrost_kbase`; sprd DRM lacks `DRM_CAP_ASYNC_PAGE_FLIP` (mailbox fallback);
running at fixed default clock (DVFS still off).

## P2 — DVFS COMPLETE (working). Smooth transitions, GLES + Vulkan clean.

**RESOLVED.** DVFS now scales 384→850 MHz under load with `simple_ondemand`;
`glmark2-es2-drm` and `vkmark` both render clean, `cur_freq`/`trans_stat` move
through the full OPP set with no watchdog hard-stops. Three fixes, in the order
they mattered:

1. **DTS soft-reset register (blocker 1 — probe mis-clock).** Use the GPU-core
   soft-reset value, `RESET_GPU_APB_GPU_CORE_SOFT_RST` (`{0x0000, BIT(0),
   0x1000}` in `ums512-clk.c`), in the node's `resets` — **not** the SYS reset.
   With `CLK_GPU_CORE` as kbase clock[0], the wrong reset made the probe-time
   soft-reset time out. Correct reset → clean probe, `/dev/mali0` + devfreq
   register.

2. **kbase clock-window: `BASE_MAX_NR_CLOCKS_REGULATORS` 2 → 4**
   (`mali_kbase_defs.h`). kbase only fetches/enables `clocks[0..N-1]` with N=2.
   Inserting the settable `CLK_GPU_CORE` composite at DT index 0 pushed
   `CLK_GPU_MEM_EB` to index 2 — past the window — so `gpu-mem-gate` never
   enabled and the GPU **stalled** (looked like the switch fault but wasn't:
   `clk_summary` showed `gpu-mem-gate ... N`). Bumping to 4 enables all four DT
   clocks (core composite + core/mem/sys EB gates). Safe on kernel 7.1: the
   regulator array there is NULL-terminated, not sized by this constant, so
   regulator setup is unaffected (`BUILD_BUG_ON` 2 > 4 still passes).

3. **Glitch-free mux switch (blocker 2).** `drivers/clk/sprd/composite.c`:
   `sprd_comp_reparent_ops` now gates the shared core-clock enable (reg 0x4
   `BIT(0)`) around the mux reparent + divider write via
   `sprd_comp_set_parent_gated` / `_set_rate_gated` / `_set_rate_and_parent_gated`
   (saves/restores the original enable bit, so it's transparent to the separate
   EB gate clk's refcount). The GPU cleanly stalls across the switch instead of
   seeing a glitched clock edge that wedged in-flight jobs. `set_rate_and_parent`
   keeps reparent+redivide inside one stopped window.

**Diagnostic note for future SPRD DVFS work:** the `t6xx: GPU fault 0x4002 from
job slot N` line is **not** a HW fault — `0x4002 = BASE_JD_EVENT_JOB_CANCELLED`
(a `base_jd_event_code`, printed as `katom->event_code`). It's the driver's own
reset cancelling in-flight atoms after the watchdog fired; the real event is a
job stuck `JS_STATUS=0x08` (ACTIVE) making no progress. Look upstream (clock /
gate state), not at the "fault".

<details><summary>Original P2 attempt notes (superseded — kept for context)</summary>

**Current shipping state: P1 fixed-clock, stable.** GPU boots at **384 MHz** (the
lowest OPP, whatever the composite's boot config leaves) and runs glmark2 at
67–103 FPS @ 720x720 with a clean probe. This is the known-good baseline. The GPU
also powers *off* when idle via the runtime-PM genpd path, so the main battery win
is already in place without DVFS.

### What was tried and why it was reverted

Two P2 changes, both **reverted in the DT** (source is back to the P1 3-gate clocks,
no `assigned-clocks`):
1. Add `CLK_GPU_CORE` (settable composite) as kbase clock index 0 so OPP/devfreq
   scales it.
2. `assigned-clocks = <&pll2 CLK_GPLL>; assigned-clock-rates = <850000000>` to make
   the 850 MHz top OPP exact (GPLL's runtime rate is register-programmed;
   `750000000` in `SPRD_PLL_HW` is the fvco param, not the rate. GPLL is
   GPU-dedicated — feeds only `gpu_parents` + diagnostic `gpll_40m`=GPLL/20).

Two distinct blockers, both confirmed on hardware:

- **(1) Probe mis-clock.** With `CLK_GPU_CORE` as clock 0, the GPU comes up
  mis-clocked and the kbase **soft-reset times out at probe** ("Failed to soft-reset
  GPU ... now attempting a hard reset"); devfreq then fails to register (probe
  rolls back → no `/dev/mali0`, no `/sys/class/devfreq/*.gpu`). Reverting the DT
  clocks makes the soft-reset timeout vanish → **this is the DT clock change, not
  devfreq** (it occurs before any scaling). Root mechanism not fully pinned; likely
  the composite/gate split (both live in reg 0x4: gate=bit0, mux=4-6, div=8-10) or
  OPP/clk init re-seeding the mux to a bad parent at probe.
- **(2) Non-glitch-free switch.** Even when rates were correct (verified:
  `gpll`=850, `gpu-core-clk` landed on valid OPP steps, `cur_freq` moved 384→850),
  the upward transition under load **hangs the GPU** — job stuck `JS_STATUS=0x08`
  (ACTIVE) → watchdog reset loop. **Undervolt ruled out**: `vddgpu` is `always-on`,
  adjustable 200mV–1.6V, sat at 0.8V (what the vendor runs 850 at), and
  `kbase_devfreq_target` does raise voltage before clk on ramp-up. So it's a genuine
  **mux glitch** reparenting the live GPU clock — the vendor avoided this with a HW
  handshake (`freq_upd_cfg`/`sw_dvfs_ctrl`/`dvfs_index_cfg`/`core_indexN_map`) that
  the generic `clk_set_rate` path does not use.

### Staged but dormant (keep — needed for the proper attempt)

- `drivers/clk/sprd/composite.c` + `.h`: `sprd_comp_reparent_ops` /
  `sprd_comp_determine_rate_reparent` (walk parents, pick parent+divider for highest
  rate ≤ target, set `best_parent_hw`). **Verified to produce correct rates.**
- `ums512-clk.c`: `gpu_core_clk` uses `SPRD_COMP_CLK_DATA_REPARENT`. Dormant because
  nothing calls `clk_set_rate` on it while the DT is reverted; the clean probe
  confirms it's harmless to leave in.
- `build_mali_kbase.sh` sets `CONFIG_LARGE_PAGE_SUPPORT=y` (independent of DVFS;
  runtime knob is the `large_page_conf` module param, default off).
- `ums512_defconfig` dma-heaps (P1 dependency, keep).

### Plan for the proper DVFS session

1. **Fix the probe mis-clock (blocker 1) first.** Determine why `CLK_GPU_CORE` as
   clock 0 breaks soft-reset. Candidates: seed the mux to a valid parent before
   kbase resets; or don't hand the composite to kbase's enable list at all — instead
   scale it out-of-band. Bisect by re-adding the clocks change *without* the GPLL
   assign to see which of the two triggered it (only re-tested together so far).
2. **Glitch-free switching (blocker 2).** Preferred: gate `CLK_GPU_CORE_EB` (the
   core clock enable, reg 0x4 bit0) around the composite mux switch in the clk
   driver so the clock is cleanly stopped/restarted (GPU just stalls, can't glitch).
   Alternative: implement the SPRD DVFS HW handshake (those syscon regs are NOT in
   the mainline DT node — would need adding, à la the vendor `sharkl5Pro.c`).
   Fallback: single-parent divider-only OPP set (pin one PLL, no mux switch) —
   loses the clean 384/512/614.4/768/850 set.
3. **Test method:** pin steady-state per freq with the `performance`/`powersave`
   governors (or min/max_freq) to validate each OPP alone *before* enabling
   transitions; only then let `simple_ondemand` switch under load.
4. Re-apply the GPLL=850 pin once transitions are safe (it worked — debugfs showed
   850) for the true top bin.

### Optional / unrelated
- async page-flip in sprd DRM (vsync/latency; `DRM_CAP_ASYNC_PAGE_FLIP` unsupported).

</details>

## Not the port donor

- `natt` platform glue targets `qogirl6`/`qogirn6pro` (different SoCs, custom DVFS),
  **not** `sharkl5Pro`/T618 — reference only, not a donor.
- `rogue` = IMG PowerVR DDK, unrelated.
- `gondul`'s `sharkl5Pro.c` was the **value** reference (clocks, OPP points) — those
  values now live in the mainline DT node above; its custom SPRD DVFS C is intentionally
  **not** ported (generic OPP/devfreq replaces it).
