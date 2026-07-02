# Panel / Display Bring-up — Status and History

Source of truth for the display investigation. Durable hardware facts and
build/flash recipes live in the [repo README](../README.md); the known-good register
capture lives in [DISPLAY-KNOWN-GOOD-DSI-STATE.md](DISPLAY-KNOWN-GOOD-DSI-STATE.md).

Panel: `lcd_gt911_mipi_ab021` (720x720, 2-lane RGB888 MIPI-DSI).
**Authoritative stock source is `device/stock/dtbo_decompiled/dtbo_overlay_1.dts`.**
`dtbo_overlay_0.dts` (`lcd_td4310_*`, `lcd_ssd2092_*`) is for other SKUs — ignore it.

---

## TL;DR

The panel **displays** (build #76, 2026-06-26): fbcon on-screen + boot to a Debian
login prompt. The fix was **not** any of the things chased for weeks (burst flags,
the DPU↔DSI halt handshake, DCS reads, panel power wiring). The real cause was that
**the kernel's own panel `prepare`/`unprepare` was tearing down the panel state
U-Boot had already set up.** Skipping that first cycle keeps the panel lit.

**UPDATE 2026-06-26: cold kernel-native init is SOLVED** — the panel now lights
from cold with `handoff_skip_first_cycle = false`, no U-Boot handoff needed, via
two fixes: `prepare_prev_first` (bridge ordering) + arming the clock lane in
`sprd_dsi_bridge_pre_enable` before the panel's init writes. See the SOLVED
section below.

---

## What is CURRENTLY working (the resolved path)

### The recipe (all committed on `ums512`)

Three changes, together, give a live panel:

1. **Skip the kernel's first panel prepare/unprepare cycle** — the load-bearing fix.
   `static bool handoff_skip_first_cycle = true;` in
   `drivers/gpu/drm/panel/panel-generic-dsi.c`. On the first prepare/unprepare the
   driver assumes U-Boot left the panel fully initialized and does NOT drive its
   reset/power-down/init sequence, so U-Boot's working panel state is preserved.
   `sprd_dpu`/`sprd_dsi` still reset themselves; this only suppresses the
   *panel-side* teardown. Commit `0881f09c` (flag), `62860e67` (comment/warning).
2. **DSI-side DPI halt disabled** — `sprd_dsi_set_work_mode()` writes
   `DSI_MODE_CFG = 0` for video mode (not `DSI_VIDEO_HALT_EN`). Commit `168285f6`.
3. **DPU-side DPI halt disabled** — `sprd_dpu_init()` clears `BIT_DPU_DPI_HALT_EN`
   (does not set it). Commit `168285f6`.

### Why it works

- The DPU/DSI/DPHY pipeline was always healthy: PLL locked at 551.488 MHz, DPHY
  analog powered, 2-lane RGB888 burst video, correct 720x720 timing, no
  timeouts/underflows. Pixels were reaching the DSI host correctly the whole time.
- (2)+(3) make **both halt halves off so the DPU free-runs.** This matches the only
  register fingerprint ever seen to light the panel:
  `DPI_CTRL=0x0`, `DSI_MODE_CFG=0x0`, `PHY_STATUS=0x1f02` (data lanes in HS, NOT
  parked in stopstate). Enabling either halt half flips `PHY_STATUS` to `0x1f32`
  (lanes in stopstate) → black. Full capture in DISPLAY-KNOWN-GOOD-DSI-STATE.md.
- (1) is what actually unblocked the display: with the kernel re-running the panel
  reset/init from cold, the panel went black regardless of pipeline health. The
  kernel-native panel init does not correctly bring this panel up; skipping it and
  inheriting U-Boot's init does.

### Confirmed-good signals

- Working boot (build #67, U-Boot handoff): `handoff: skipping first prepare`,
  `DPUDUMP ... DPI_CTRL=00000000`, fbcon switch.
- Broken kernel-native boot (build #73): identical pipeline but
  `DPI_CTRL=00010000` + `DSI_MODE_CFG=0x2` (both halts armed),
  `PHY_STATUS=0x1f32`, no panel.

  (These two register fingerprints were captured from a good/bad dmesg diff pair
  during display bring-up; the raw logs have been removed — the values above are
  the record.)
- Live scanout buffer is the DRM GEM/CMA framebuffer, IOVA `0x90000000` through the
  DPU IOMMU (physical pages in the `linux,cma` pool at `0x137e00000`). It is NOT
  U-Boot's `framebuffer-region@9e000000`; the IOVA/`iq-mem@90000000` collision is a
  coincidence (different address spaces). fb0 writes land where the DPU reads.

### Reference binary

`device/images/boot_custom.img.prehandoff` = build #67 (Jun 24 14:25), the
first image to display. It predates the halt edits and already used the handoff skip.
Its **source was never committed and is unrecoverable** (no git commit, not in VSCode
local history); only the binary survives. Keep it as the golden A/B reference.

### DO NOT flip the handoff flag

`handoff_skip_first_cycle = false` is exactly what regressed the panel to black.
Only set it false as a deliberate cold-init diagnostic, or once we are confident the
kernel can cold-init the panel without U-Boot. The warning is duplicated at the flag
declaration and in commit `0881f09c`.

---

## The remaining problem: cold kernel-native init — DECISIVELY panel-side (2026-06-26)

The working path leans on vendor U-Boot having lit the panel. For a self-contained
boot chain the kernel must bring the panel up from cold (`handoff_skip_first_cycle
= false`), which currently fails. **A live experiment on build #76 narrowed this to
the panel chip itself**, not the DPU/DSI host pipeline:

**Experiment (runtime, on the working #76 image):** unbind then rebind the panel
driver to force a full native `unprepare`→`prepare` on a warm system:
`echo 20400000.dsi.0 > /sys/bus/mipi-dsi/drivers/panel-generic-dsi/{unbind,bind}`.
- Unbind hit the handoff-skip `unprepare` (no real teardown) and cleared the flag to
  false; rebind therefore ran **full native init** (reset + 144 DCS + sleep_out +
  `display_on (cmd-mode) ret=0`).
- After native init the DSI host returned to the **exact known-good fingerprint**:
  `PHY_STATUS=0x1f02`, `DSI_MODE_CFG=0x0`, `LAYDUMP base=90000000`, fbcon reattached,
  DPU scanning. Indistinguishable from the working handoff state at the register level.
- Then `dd if=/dev/urandom of=/dev/fb0 bs=2073600 count=1` (one full screen of noise)
  while PHY_STATUS stayed `0x1f02` (DPU provably scanning the noise out).
- **Panel: pure black.** A non-black buffer, demonstrably being scanned out, over a
  DSI host whose registers match the working state, produces nothing on the glass.

**Conclusion:** the DPU/DSI controller side is not the variable. The panel chip does
not accept the kernel's native reset + DCS init. U-Boot's panel init is doing
something to the *panel* that the kernel's `prepare` does not reproduce, and once the
kernel disturbs it (or inits from cold) the panel will not light. This is the entire
remaining display bug.

(Recovery from this state is a reboot — the on-disk #76 image still has
`handoff_skip_first_cycle = true`, so the next boot returns to the working display.)

Side finding: the unbind path throws two non-fatal kernel `WARNING`s — a
`drm_bridge_put` refcount underflow / use-after-free
(`devm_drm_panel_bridge_release`) and a `drm_vblank_init_release` WARN. Real teardown
refcount bugs in the sprd driver; fix before relying on runtime unbind/rebind.

### SOLVED (2026-06-26): cold kernel-native init works — `prepare_prev_first` + early clock-lane

**Cold kernel-native init now lights the panel** (`handoff_skip_first_cycle = false`):
fbcon on the panel from both USB-plug and power-button boot, no U-Boot handoff
dependency. The two-part fix below resolved the months-long cold-init wall.

**Fix 1 — bridge/panel ordering.** `ctx->panel.prepare_prev_first = true` in
`panel-generic-dsi.c` probe. Without it the panel's `prepare` (144 init DCS) ran
*before* `sprd_dsi_bridge_pre_enable` had reset/initialised the host, and sprd_dsi
then reset the controller, wiping the init. Setting it forces sprd_dsi pre_enable
first (controller up + LP cmd mode), then the panel init — the vendor U-Boot order.

**Fix 2 — arm the clock lane before init writes.** With ordering fixed, the first
init write timed out: `tx cmd fifo is not empty` / `panel init command 0xff failed:
-110`. The clock-lane auto-HS control (`AUTO_CLKLANE_CTRL_EN`) was only set in
`sprd_dsi_bridge_enable`, which now runs *after* the panel's writes, so the clock
lane couldn't engage and the command FIFO never drained. Moved the clock-lane
enable into `sprd_dsi_bridge_pre_enable` (after LP cmd enable, before
`set_work_mode(DSI_MODE_CMD)`). This matches the warm rebind state (clock lane
already up) where writes had always succeeded. After this, `display_on (cmd-mode)
ret=0`, init completes, DPU scans (`DPUDUMP stopped=0 DPI_CTRL=0`), fbcon attaches.

Both fixes are now the default in-tree (handoff flag left `false`). The reference
DISPLAY-KNOWN-GOOD-DSI-STATE fingerprint still applies. Remaining follow-ups:
fix the unbind/rebind refcount WARNs and the DSI short-read path (observability),
neither blocks display.

---

### Original experiment writeup (kept for the diagnosis trail): `prepare_prev_first` bridge ordering

A static diff of the **vendor U-Boot panel-light path** against the kernel
cold-init `prepare` found an **inverted bridge/panel ordering** that plausibly
explains the entire cold-init failure. Vendor U-Boot is the same BSP as the
stock U-Boot doing the working handoff, and its panel logic is DT-driven source
we can read directly (`src/u-boot/drivers/video/sprd/`).

**Vendor order (`sprd_panel_probe` -> `panel_ops_mipi.c`), one linear function:**
`power(true)` (rails + reset high50/low50/high120) -> `read_id()` -> `init()`,
where `init()` is: `mipi_dsi_lp_cmd_enable(true)` -> send 144 init DCS **in LP**
-> `set_work_mode(VIDEO)` -> `state_reset` -> `mipi_dphy_hs_clk_en` **last**.
Invariant: **DSI host is fully up and in LP command mode before any init byte;
HS clock comes on after init.**

**Kernel order (cold boot):** the panel attaches as a `panel_bridge` downstream
of `sprd_dsi.bridge`. `drm_atomic_bridge_chain_pre_enable()` walks the chain in
**reverse**, and our panel never set `prepare_prev_first`, so:
1. `panel_bridge.pre_enable` -> `generic_panel_prepare` sends all 144 init DCS
   (+ sleep_out/display_on/reads) **first**, while
2. `sprd_dsi_bridge_pre_enable` **hasn't run** -- controller not
   reset/`sprd_dsi_init`/`sprd_dphy_init`'d, `CMD_MODE_LP_CMD_EN` not armed --
   and when it does run it immediately `sprd_dsi_reset()`s the controller,
   wiping whatever the panel just sent.

So the kernel transmits panel init into an **un-initialised, non-LP-cmd-mode**
controller, then resets it. The panel never latches init -> black. The handoff
path dodges this because `prepare` returns immediately. This also fits the
unbind/rebind black result (there `prepare` re-sent init while the controller
sat in **video** mode, not LP cmd -- same fault class, different trigger), and
the "#76 panel-side, not controller-side" conclusion (controller regs end up
right, but the *init handshake to the panel* happened at the wrong time/mode).

**Staged changes (in `panel-generic-dsi.c`, ready to build+flash, NOT yet
tested on HW):**
- `ctx->panel.prepare_prev_first = true;` in probe -> propagates to
  `pre_enable_prev_first` (`drm/bridge/panel.c:302`), forcing
  `sprd_dsi_bridge_pre_enable` to run **before** the panel's `prepare`
  (controller up + LP cmd mode first, then init DCS) -- the vendor order.
- `handoff_skip_first_cycle = false` (the deliberate cold-init diagnostic; this
  is the only meaningful config for the experiment). Recovery is a reboot to the
  on-disk image / reflash; set back to `true` to restore the working display.
- The 3 diagnostic DCS reads at the end of `prepare` are `#if 0`'d out -- they
  BTA on the broken short-read path and park the lanes (`0x1f02`->`0x1f32`),
  a cold-init-only confound (handoff skips them).

Expected pass signal: panel lights from cold (no U-Boot handoff dependency),
`PHY_STATUS=0x1f02`, fbcon visible. Expected fail signal: still black ->
ordering was necessary but not sufficient; move to wire/timing comparison below.

Tractable next steps:

1. **Why the kernel-native panel reset/init kills a panel U-Boot can light.** The
   delta is now provably panel-side. Compare the kernel `prepare` against vendor
   U-Boot's `vlx_nand_boot(... LCD_ON)` on the *wire/timing*, not the values: reset
   waveform durations and ordering vs the DCS sequence, regulator settle times, and
   especially **LP command-link setup** (continuous vs non-continuous clock-lane, the
   parked `sprd,phy-escape-clock=20000` / 20 MHz LP-rate suspect — U-Boot's LP DCS
   provably reaches the panel; the kernel's may not be clocked the same).
2. **DCS short-read path** (see below) to regain panel observability — right now we
   are blind to whether/where native init's DCS commands reach the panel.

---

## Dead ends — do not retry (each ruled out with evidence)

These were all chased while the root cause (kernel panel teardown) was misdiagnosed
as a pixel-path problem. None lit the panel; most are kept because they are correct
on their own merits.

- **DPU↔DSI halt handshake** — the long-running theory that the panel was black
  because the halt handshake wasn't completing. Wrong direction entirely: the
  *halt-off* free-run config is what works; arming either halt half blanks it.
- **Burst flags `flags=1`→`flags=3`** — necessary for the DSI host setup math
  (non-burst flags are rejected: "current resolution can not be set"), and it did
  put the lanes in HS, but it was not the blocker. Kept.
- **DPU-RUN-last ordering** — issuing `sprd_dpu_run()` after the DSI video FSM is
  armed; made the pipeline look clean but did not light the panel. Kept (correct).
- **`display_on` in CMD mode vs `.enable`** — moving `SET_DISPLAY_ON` before video
  mode returns ret=0 but changes nothing visible. Kept (matches vendor).
- **Panel power AVDD/AVEE/reset wiring** — GPIO 15 (AVDD), 138 (AVEE), 50 (reset)
  all verified asserted at the pins; driver's logical `0,1,0` + `GPIO_ACTIVE_LOW`
  = stock's physical `HIGH/LOW/HIGH`. Do NOT flip the reset polarity flag alone (it
  inverts the waveform and holds reset). No I2C bias chip exists on this board.
- **DTS "missing hardware enable" hunt** — vs working infinix x6816d + stock dtb:
  DPHY en/pwr syscons match stock; MM power-domain attachment is not required
  (infinix works without it). Nothing a working board has that we lack.
- **HS vs LP init transport** — vendor sends the whole init in LP too; no difference.
- **Init-table transcription** — 144 live init commands byte-match stock's 146
  (stock's extra two are sleep_out/display_on sent separately). Not a typo.
- **DSI mode-flag burst-family permutations** (`3/515/1027/1539`) — identical
  behavior, panel black. (The non-burst rejection is the clue behind `flags=3`.)
- **Track-2 vendor deltas** (`mipi_dsi_state_reset` + `mipi_dphy_hs_clk_en`) — the
  controller was already in their end-state; porting them does nothing in isolation.
- **Reset re-pulsing / `state_reset` re-pulse** — no effect.
- **Driver unbind/rebind** (full kernel-native re-init) — runs to completion, panel
  stays black. (In hindsight: this is the *cold-init* failure, the real open bug.)
- **`max_rd_time` 6000→0x8000**, **DCS 0-param encoding**, **HSYNC/VSYNC polarity**
  — all correct/kept, none changed the display.
- **Forced framebuffer flips (`FBIOPAN_DISPLAY`) / white fb0 fill** — pipeline
  pushes a solid white frame, panel stays black. Not a flip/scanout problem.
- **Boot-path unification (which power-on trigger)** — the same wall appeared on
  both handoff and kernel-native paths, so this could not be the fix. (Correct at
  the time, but the framing missed that *handoff itself* was the working ingredient.)

## Known-broken but not blocking the working path

- **DSI short-DCS read path** — every panel-state read returns `-EIO` / "rx payload
  fifo empty". `RDCMD_DONE` sets but `GEN_CMD_RDATA_FIFO_EMPTY` stays 1: the
  Synopsys controller stuffs short responses somewhere other than `GEN_PLD_DATA`.
  Blinds us to panel state; needed for cold-init observability. Read algorithm
  itself matches vendor byte-for-byte, so the bug is in read preconditions/state.
- **DPU frame-DONE (`INT_RAW` bit0) behavior** under free-run — expected with halt
  off; not an independent bug.

---

## Observability and hazards (durable — stop relearning these)

- **No UART pad exists** (case opened, confirmed). The only interactive channel is
  kernel USB CDC-ACM (`0525:a4a7` → host `/dev/ttyACM0`), available once Linux boots.
  Vendor U-Boot console is on UART0 (no pad); its only interactive USB channel is
  fastboot (`18d1:4ee0`). (The mainline-ish U-Boot fork that used to be parked
  at `src/u-boot-sprd` showed no liveness on this hardware at all and has been
  dropped — see [BOOT-CHAIN.md](BOOT-CHAIN.md). `src/u-boot/` is now the vendor
  BSP fork, the tree actively being taught extlinux hand-off.)
- **USB serial can drop on a bad power/enumeration state.** After a flash, a full
  power-off→power-on (not warm reset) is required; if `ttyACM0` doesn't enumerate,
  power-cycle again before assuming a regression.
- **Live MMIO** via `/usr/local/bin/devmemn ADDR [VAL]` (32-bit). The value is the
  *second* arg and is a WRITE — `devmemn 0x20400004 32` writes 0x20. Address-only
  is a read.
- **Do NOT `devmemn`-read DPU register space (`0x20300000`+).** It hangs the device
  and drops the USB gadget (needs a physical power-cycle). DSI-host space
  (`0x20400000`+) reads fine. Read DPU registers only via in-driver dmesg/INT
  instrumentation. DPU offsets in CLAUDE.md are valid for in-driver use.
- **Do NOT `cat /dev/urandom > /dev/fb0` unbounded** — drops the host `ttyACM0`
  node. Use bounded `dd count=` / `perl` writes. (`tr | dd` writes can fail silently
  — verify with a `head` read.)
- **Do NOT `echo 4/0 > /sys/class/graphics/fb0/blank`** — wedges the console path.
- **`regulator_ignore_unused` must stay on the cmdline** — otherwise eMMC/storage
  regulators drop and userland binaries stop loading mid-session.
- `PHY_STATUS` (`0x2040009c`): `0x1f02` = data lanes in HS (good), `0x1f32` = lanes
  parked in stopstate (blanked). DCS reads bounce it to `0x1f32` via the BTA.
