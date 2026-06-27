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
  (mainline `bq2415x`), pads identified, an off-by-one pinmux bug found and fixed
  in the DTS — but the i2c4 bus is still electrically dead in live testing. See
  "Charger / i2c4" below. **This is where to resume.**

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

## Open hypotheses for the dead bus (next steps)

In rough priority:

1. **Clean-boot test of `func2`.** Live `devmemn` test sets the same final pad
   state as `func2`, *but* the controller was probed at boot with the wrong pads;
   reflash with `func2` so it inits correctly from cold. Cheapest definitive
   test even though analysis suggests it may not be sufficient.
2. **Read the i2c4 controller status register** to see actual SCL/SDA line state.
   Controller base: DT `i2c@700000` reg `<0 0x700000 0 0x100>` — **resolve the
   absolute address via the `apb@70000000` `ranges`** (was mid-lookup; the apb
   ranges in `ums512.dtsi` need walking — i2c4 is not one of the already-listed
   `0x323xxxxx`/`0x327xxxxx` sub-ranges, find the AP-APB one). Reg offsets:
   `I2C_CTL=0x00, I2C_ADDR_CFG=0x04, I2C_COUNT=0x08, I2C_STATUS=0x14,
   ADDR_DVD0=0x20, ADDR_DVD1=0x24`. `I2C_STATUS` bits (see `i2c-sprd.c` "/* I2C_STATUS */")
   should reveal whether SDA/SCL are stuck low (chip holding / no effective pull)
   or idle-high (electrically fine ⇒ controller/chip-ACK problem).
3. **Mux SIMCLK2/SIMDA2 to GPIO input and read the line levels** to see if the
   bus idles high (pull works) or is stuck low (no pull / chip clamps).
4. **Charger chip power.** The AW32257's logic/VDDIO supply may be off in
   mainline; if the chip holds the bus low, START never completes → `-110`. Check
   what rail powers it (stock dtbo `charger@6a` had `phys=<&hsphy>`,
   `extcon=<&extcon_gpio>`, an `otg-vbus` regulator — none wired in our node).
5. **Wrong pads for THIS board.** pinmap.c is the reference IRD board
   (`UMS512_1_IRD_A` per its header); RG Rotate could route i2c4 differently —
   though i2c4 (AP I2C ctrl 4) can only surface on pads offering it as a func,
   and SIMCLK2/SIMDA2 are the reference choice.

## Useful device-side workflow

- **Serial console** is bash on `/dev/ttyACM0` (autologin root). readline garbles
  fast writes — drive it byte-by-byte (~15 ms/char) with a leading Ctrl-U +
  throwaway space. Reusable helper used this session lived at
  `/tmp/.../scratchpad/tac.sh` (per-session scratch; recreate as needed).
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
