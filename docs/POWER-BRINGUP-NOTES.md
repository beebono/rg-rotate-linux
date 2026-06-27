# Power / PMIC / Charger bring-up notes

Status as of 2026-06-27. Companion to `CLAUDE.md` (checklist line "Power / PMIC /
fuel gauge"). All changes are in `src/linux-mainline-6-16-sprd` and reach the
device via `tools/scripts/build_vendor_boot_img.sh` + `write_part
vendor_boot_a` (DTB only; no kernel rebuild required for any of this).

## TL;DR

- **PMIC (SC2730): healthy.** Regulators, watchdog, vibrator all live. No work needed.
- **Fuel gauge (SC2730 FGU): DONE, verified on HW.** `/sys/class/power_supply/sc27xx-fgu`
  reports voltage/SoC/temp/charge. See "Fuel gauge" below.
- **Charger (AW32257): IN PROGRESS, blocked on i2c4 bus.** Driver choice solved
  (mainline `bq2415x`), pads confirmed correct (SIMCLK2/SIMDA2 @ AF1), pinmux
  off-by-one fixed. Live probe (2026-06-27) narrowed the dead bus to **the i2c4
  completion interrupt never firing (GICv3 47 = irq 19, 0 counts)** — NOT pinmux,
  chip power, or clock (all ruled out). Now interrupt-broken vs. electrically-stuck;
  needs a kernel-side `I2C_STATUS` dump to decide (devmem can't read 0x700000 —
  STRICT_DEVMEM). See "2026-06-27 live-probe session" below. **This is where to resume.**

## Files changed

Only one file so far: `arch/arm64/boot/dts/sprd/ums512-1h10.dts`. No `.c` /
Kconfig changes — every driver needed is already built in
(`CONFIG_SC27XX_FUEL_GAUGE`-equivalent `sc27xx_fuel_gauge`, `CONFIG_CHARGER_BQ2415X=y`,
`CONFIG_I2C_SPRD=y`).

### 1. Fuel gauge (working)

Added a `simple-battery` node `bat` and enabled `&sc2730_fgu`, mirroring the
in-tree `ums512-infinix-x6816d.dts` pattern. Battery profile (1900 mAh, 4.34 V
CCV, 21-point OCV table) transcribed from the authoritative stock overlay
`device/stock/dtbo_decompiled/dtbo_overlay_1.dts` (`battery` node), converting the
hex µV/µAh values to decimal. `sprd,calib-resistance-micro-ohms = <10000>`
matches the stock overlay (0x2710).

Verified live: `voltage_now≈4.349V, capacity=100%, charge_now=1.900Ah, temp=33C,
present=1`. The FGU logs `get charger status error` because no charger
power_supply is registered yet (expected until the charger lands).

### 2. Charger / i2c4 (blocked — resume here)

Added `&i2c4` (enabled, 400 kHz) with a `charger@6a` node + a `&pinctrl` block
with two groups wired via `pinctrl-0`. Current DTS state:

```
&pinctrl {
	i2c4_pin_func: i2c4-pin-func {
		pins = "UMS512_SIMCLK2", "UMS512_SIMDA2";
		function = "func2";          /* AF1 — see off-by-one note */
	};
	i2c4_pin_misc: i2c4-pin-misc {
		pins = "UMS512_SIMCLK2_MISC", "UMS512_SIMDA2_MISC";
		bias-pull-up = <4700>;        /* WPUS|WPU, matches u-boot */
	};
};
&i2c4 {
	status = "okay";
	clock-frequency = <400000>;
	pinctrl-names = "default";
	pinctrl-0 = <&i2c4_pin_func &i2c4_pin_misc>;
	charger@6a {
		compatible = "ti,bq24158";
		reg = <0x6a>;
		ti,current-limit = <1800>;            /* mA */
		ti,weak-battery-voltage = <3400>;     /* mV */
		ti,battery-regulation-voltage = <4200>;
		ti,charge-current = <2000>;
		ti,termination-current = <200>;
		ti,resistor-sense = <33>;             /* mOhm (0x21) */
	};
};
```

**NOTE:** the in-tree binary `vendor_boot_custom.img` was last repacked with the
*earlier* `function = "func1"` + `bias-pull-up = <20000>`. The DTS now has the
corrected `func2` / `4700` but **has not been rebuilt/reflashed yet** — first
action on resume is `build_vendor_boot_img.sh` then flash `vendor_boot_a`.

## What we learned (the investigation trail)

1. **bq2415x is the right driver.** AW32257 (Awinic, i2c4 @0x6a) is a register
   clone of TI bq24157/bq24158 and uses the bq2415x DT binding. The driver
   *binds* (`bq2415x-charger 4-006a`); it only fails at the first I2C write.
   Probe failure is non-fatal to the test — `bq2415x_set_defaults` ignoring
   setter errors means out-of-range tuning won't block probe; only I2C does.
   Binding units are **mA/mV** per `bq2415x.yaml` (NOT µA like bq24257.yaml);
   stock vendor values were µA for currents / mV for voltages → converted.

2. **The whole i2c4 bus is dead, not just the charger.** A userspace perl
   `I2C_SLAVE` probe (no i2c-tools on target; perl present) of 0x6a/0x6b/0x10/0x36
   *all* time out at ~1 s → `-ETIMEDOUT`. The sprd i2c driver (`i2c-sprd.c`,
   matches `sprd,ums512-i2c`) reports a chip NAK as `-EIO` and a no-completion as
   `-110`; `-110` everywhere ⇒ bus not toggling, not a chip issue. Clock ruled
   out: `ap-i2c4-clk`=26 MHz on ext-26m in clk_summary; `i2c4-eb`=N is just
   runtime-PM idle (driver enables it per-transfer).

3. **i2c4 pads identified.** UMS512 has **no** dedicated SCL4/SDA4 pads. From the
   vendor u-boot board pinmap
   `vendor/u-boot-unisoc-bsp/board/spreadtrum/ums512_1h10/pinmap.c`:
   `REG_PIN_SIMCLK2 = BITS_PIN_AF(1)  //I2C4_SCL`,
   `REG_PIN_SIMDA2  = BITS_PIN_AF(1)  //I2C4_SDA`, both MISC `WPUS|WPU`.
   (That file is **ISO-8859 encoded** — plain `grep` silently misses lines, use
   `grep -a`. The earlier RFFE1_SDA guess was wrong: it's AF3 = EAR_CTL2 GPIO.)

4. **Off-by-one pinmux bug FOUND + FIXED.** `sprd_pmx_set_mux()` in
   `drivers/pinctrl/sprd/pinctrl-sprd.c`: `PIN_FUNC_1` (DT string `"func1"`)
   clears the func bits → **AF0**. So sprd DT naming is 1-indexed vs hardware AF:
   `"func1"`=AF0, **`"func2"`=AF1**, `"func3"`=AF2, `"func4"`=AF3. I2C4 is AF1 ⇒
   must use `"func2"`. (Cross-check: GPIO use of KEYOUT/SCL3 pads is `"func4"` in
   the in-tree infinix board = AF3, which matches u-boot's `BITS_PIN_AF(3)` for
   those as GPIO. Consistent.) `bias-pull-up`: `4700`→WPUS|WPU (bit12|bit7),
   `20000`→WPU only (bit7); u-boot uses both ⇒ 4700.

5. **BUT live testing still shows a dead bus.** Using `devmemn` on the running
   device (pinctrl base `0x32450000`):
   - SIMCLK2 mux reg `0x324500b0`, SIMDA2 `0x324500b4` (func/COMMON regs).
   - SIMCLK2_MISC `0x324504b0`, SIMDA2_MISC `0x324504b4` (pull/drive regs).
   - Wrote AF1 (`0x10` = BIT4) to both mux regs and WPUS|WPU (`0x83088`) to both
     MISC regs — confirmed read-back — then re-ran the perl probe: **still all
     `-ETIMEDOUT`.** The mux value persisted (didn't get re-applied/reverted).
   - Since `i2c-sprd.c` fully re-inits the controller every transfer
     (`sprd_i2c_enable` re-writes `I2C_CTL`, clk, thresholds), a boot-time
     controller wedge is unlikely to survive a fresh transfer — so pinmux alone
     may not be the whole story.

## 2026-06-27 live-probe session — narrowed to interrupt-or-electrical

A full live probe on a fresh boot (device up on `/dev/ttyACM0`, charging) settled
most of the open hypotheses. **The dead bus is NOT pinmux, NOT chip power, NOT the
clock.** Findings, in order:

1. **i2c4 controller absolute base = `0x00700000`** (confirmed via `/proc/iomem`:
   `00700000-007000ff : 700000.i2c`; it is `i2c-4`). The `apb`/`soc` `ranges` are
   genuinely identity (empty `ranges;`), so the DT `reg 0x700000` is literal — the
   AP-APB peripherals really do sit at these low physical addresses. So
   `I2C_STATUS = 0x00700014`. **BUT** `devmemn` of `0x700000` returns fixed garbage
   (`0x7911193e`/`0x50e2f75b`) idle *and* mid-transfer — almost certainly
   `CONFIG_STRICT_DEVMEM` blocking this low (~7 MB) physical range (devmem reads
   the high `0x32450000` pinctrl block fine). **So I2C_STATUS is NOT readable via
   devmem** — need a kernel-side dump instead (see next steps).

2. **Live boot was running the stale/wrong pinmux** (as predicted — `func2` DTS not
   reflashed): mux regs `0x324500b0/b4 = 0x0` (AF0), debugfs showed
   `function func1` on SIMCLK2/SIMDA2. Forced AF1 live (`0x10` to both mux regs)
   + WPUS|WPU (`0x83088` to both MISC regs), confirmed readback → **probe to 0x6a
   STILL `-110`/ETIMEDOUT.** Pinmux is not sufficient. (Reflashing `func2` is still
   worth doing for a clean baseline, but will not by itself fix the bus.)

3. **Pads are the correct ones for THIS board.** `ums512_1h10/pinmap.c` confirms
   `REG_PIN_SIMCLK2/SIMDA2 = BITS_PIN_AF(1)  //I2C4_SCL/SDA`. (Note: sharkl5pro
   *phone* boards like `sp9861e_*` use dedicated `REG_PIN_SCL4/SDA4` instead — a
   red herring; our handheld board uses SIMCLK2/SIMDA2 like the sp9863a family.)

4. **Chip power is fine.** Kernel cmdline shows `androidboot.mode=charger` +
   `bootcause="in charging during shutdown"` — the AW32257 is powered and charging
   the battery autonomously right now. Rules out the "VDDIO off / chip unpowered"
   hypothesis.

5. **The functional clock is on during transfers.** `clk_summary` sampled while a
   background probe loop kept the bus busy: `i2c4-eb` enable_cnt=1, `Y`, consumer
   `700000.i2c`; `ap-i2c4-clk` `Y` @ 26 MHz. So the controller is clocked.

6. **The completion interrupt NEVER fires.** `/proc/interrupts`: i2c4 is
   `19: 0 0 0 0 0 0 0 0  GICv3 47 Level  700000.i2c` — **0 counts on all CPUs**,
   even after this session ran dozens of probe transfers. The sprd i2c driver
   (`i2c-sprd.c`) completes via `wait_for_completion_timeout` driven by the ISR, so
   **0 interrupts ⇒ guaranteed `-110` on every address** (matches the symptom: all
   addresses time out identically).

### Remaining ambiguity: interrupt path vs. electrically-stuck bus

0 interrupts is consistent with BOTH:
- **(A) interrupt broken/masked** — controller transacts but the IRQ never reaches
  the CPU (GIC SPI 15 = hwirq 47 mapping looks correct & is registered to
  700000.i2c, so this would be a mask/routing/affinity issue), OR
- **(B) bus electrically stuck** — a line held low (no effective external pull, or
  the chip clamping), so the controller never wins bus-free/START, never completes,
  never raises its done/error IRQ.

devmem can't read `I2C_STATUS` to tell these apart (STRICT_DEVMEM). The two cheap
ways forward:

1. **Kernel-side `I2C_STATUS` dump (recommended).** We rebuild `vendor_boot`
   anyway — add a one-line `dev_err` in the timeout branch of `sprd_i2c_xfer`/the
   completion-timeout path in `drivers/i2c/busses/i2c-sprd.c` dumping `I2C_STATUS`
   (offset 0x14) and `I2C_CTL`. Bits (see the `/* I2C_STATUS */` defs in that file)
   reveal SDA/SCL line state + busy/arb-lost → distinguishes (A) vs (B)
   definitively. Bundle with the `func2` reflash so it's one boot.
2. **GPIO line-level read** — mux SIMCLK2/SIMDA2 to GPIO input and read levels
   (idle-high ⇒ pulls OK, favors (A); stuck-low ⇒ favors (B)). More fiddly than
   the kernel dump.

If (A): check GIC config for SPI 15 / IRQ affinity / whether the driver actually
unmasks the controller IRQ enable bits. If (B): the SLP_* bits in the stock MISC
config (`BIT_PIN_SLP_AP|BIT_PIN_SLP_WPU|BIT_PIN_SLP_Z`, which our DT pull setting
omits) or a missing board-level external pull-up are the leads.

### Older hypotheses now CLOSED by the above
- ~~Clean-boot `func2` test~~: necessary baseline but proven insufficient (item 2).
- ~~Wrong pads for this board~~: closed, pads confirmed (item 3).
- ~~Charger chip power off~~: closed, chip is powered/charging (item 4).

## Useful device-side workflow

- **Serial console** is bash on `/dev/ttyACM0` (autologin root). readline garbles
  writes badly, and worse when **bracketed-paste mode** is on. What actually worked
  this session: (1) `stty -F /dev/ttyACM0 raw -echo 115200`; (2) hold the port open
  on one fd (`exec 3<>port`) instead of reopening per byte; (3) **send each char
  with a `sleep` and a leading Ctrl-U (0x15)** to clear the line — `0.04 s/char`
  for short cmds, `0.07 s/char` for long/quoted ones (length, not just speed,
  drives garbling — likely half-duplex echo contention on the ACM pipe);
  (4) **disable bracketed paste once**: `bind 'set enable-bracketed-paste off'`.
  Read with a backgrounded `timeout N cat /dev/ttyACM0 > log`, then strip with
  `tr -d '\000' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'`. Long single lines with many
  `;`/quotes still corrupt — prefer short sends or drop a script onto the device.
- **`devmemn <addr> [val]`** on target: read (addr only) / write (addr+val) MMIO.
- **No i2c-tools**, but **perl** is present — userspace bus probe:
  ```
  perl -e 'for my $a (0x6a,0x6b,0x10,0x36){open(F,"+<","/dev/i2c-4")||die;
    ioctl(F,0x0703,$a)||next; my $b; my $r=sysread(F,$b,1);
    printf("0x%02x: %s\n",$a,defined($r)?"ACK":"ERR=$!"); close F}'
  ```
- **Pinmux debug:** `/sys/kernel/debug/pinctrl/32450000.pinctrl/pinmux-pins`
  (shows owner/function/group), `.../pins` (no reg addr though). Pad reg formula
  (replayed from `pinctrl-sprd.c`): COMMON `reg = 0x32450000 + 0x34 +
  4*(array_index - 63)`; MISC `= 0x32450000 + 0x434 + 4*(array_index - 63 -
  common_count)`; 63 = GLOBAL_CTRL pins preceding (computed via the python
  replay in chat — re-derive if pad set changes).
