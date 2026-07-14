# USB gadget console — cold (power-button) boot enumeration — Status and History

> **Superseded (2026-07-13):** USB is now full automatic dual-role OTG driven by
> the PMIC Type-C port manager (`sc27xx_pd`) — see
> [USB-OTG-HOST-CLEANUP.md](USB-OTG-HOST-CLEANUP.md). The gadget console
> enumerates via CC role detection (plug to host → device role), and the
> userspace forced-`device` oneshots discussed below have been removed. This
> document is retained as the history of the earlier cold-boot `-71` deep-dive.

## TL;DR

The CDC-ACM gadget console (`0525:a4a7`, host `/dev/ttyACM0`) enumerates cleanly
on a **USB-plug boot** (power off, then plug in — the device boots *because* of
USB VBUS, and BROM/U-Boot init the USB PHY along the way). It does **NOT**
enumerate on a **power-button cold boot followed by a later cable plug**: the
host sees the device connect but every EP0 control transfer fails with
`device descriptor read/64, error -71`, retrying forever.

**Still unresolved as of 2026-06-26.** Working hypothesis going forward
(user's): this is a **regulator/DTS completeness** gap — some rail the stock DT
keeps up that mainline lets drop — and may resolve on its own as more of the
board (PMIC/charger/typec) is brought up. Parked here; not blocking, since the
USB-plug boot path gives a reliable console for iteration.

## Update 2026-07-05 — SD/extlinux boot ruled in; HS-trimming fix APPLIED (pending HW test)

Confirmed on the microSD/extlinux Debian boot that the *whole device side is
correct* and the failure is purely this EP0 problem: a boot-time diag
(`/var/log/usb-gadget-diag.txt`, `rgdebug` `usb-gadget-diag.service`) showed
`role=device`, UDC `musb-hdrc.11.auto` bound with `function=g_serial`,
`/dev/ttyGS0` present, and `serial-getty@ttyGS0` **active** — but
`/sys/class/udc/*/state=default` (never `configured`), i.e. the host never
finishes enumeration. A live `role=device` re-assert did nothing. Same `-71`
family; nothing SD/boot-path specific. (The rest of the SD boot — switch_root,
systemd, autologin on tty1, sshd — all work.)

**Applied the HS-trimming parity fix** (was "Next ideas" #2) in
`drivers/phy/phy-sprd-usb2.c` `sprd_hsphy_init()`: after the single
`DEFAULT_EYE_PATTERN 0x04f3d1c0` write (which leaves `TUNEHSAMP=2`), override
`TUNEHSAMP=3` (2.6mA, `0x3<<25`) and `TFREGRES=0x14` (`0x14<<19`) to match
vendor `phy-sprd-sharkl5Pro.c`. Applies on every boot, so it should fix cold
boots too. **Not yet verified on hardware.** If it works, the state-driven
reconnect daemon (Attempt #2) is still needed for the late-plug edge.

### 2026-07-05 (cont.) — trimming moved the failure ONE stage, then walled

Tested on HW. The trimming change **advanced the failure by a full enumeration
stage** but did not close it:

- BEFORE: `device descriptor read/64, error -71` (EP0 IN data stage dead).
- AFTER step 1+2: `Device not responding to setup address` →
  `device not accepting address N, error -71` (host gets *past* the descriptor
  read, now fails at SET_ADDRESS).

Trimming experiments run (all in `sprd_hsphy_init`, current state of the file):
- **Step 1:** dropped the full `DEFAULT_EYE_PATTERN` write entirely; only
  `regmap_update_bits` TUNEHSAMP=3 + TFREGRES=0x14 (true vendor-BSP behavior,
  leaving TFHSRES/TUNEOTG/etc. at silicon reset default). → still SET_ADDRESS.
- **Step 2:** additionally pinned TFHSRES=0x1F (`0x1f<<14`, mask `0x7c000`) and
  TUNEOTG=0 (mask `0xe00`), U-Boot's HS-termination profile. → **still**
  SET_ADDRESS, byte-identical dmesg. So **no trimming value crosses
  SET_ADDRESS** → the remaining blocker is NOT the HS eye/termination.

Field masks (anlg_phy_g2 USB20 TRIMMING reg, ums512 offset `0x60`): TUNEEQ
`0x7`, TUNEDSC `0x180`, TUNEOTG `0xe00`, TUNERISE `0x3000`, TFHSRES `0x7c000`,
TFREGRES `0x1f80000`, TUNEHSAMP `0x6000000`.

### DEFINITIVE reference found — real ums512 U-Boot PHY init

`src/u-boot/drivers/usb/musb-new/sharkl5pro_usb_phy.c` `usb_phy_init()` is the
actual sharkl5pro boot-path init (the AP_AHB `sprd_usb_phy.c` is a different-SoC
FDL leftover — ignore it). What the *working* path does, in order:
1. `REG_AON_APB_APB_EB1 |= USB_EB | ANA_EB` (enable USB + **analog block clock**).
2. `OTG_PHY_TEST |= VBUS_VALID_PHYREG` **and** `USB20_UTMI_CTL1 |= VBUSVLDEXT`
   (VBUS valid asserted **early**).
3. `OTG_PHY_CTRL |= UTMI_WIDTH_SEL` (16-bit) and `UTMI_CTL1 |= DATABUS16_8`.
4. `APB_RST1 |= OTG_PHY_SOFT_RST | OTG_UTMI_SOFT_RST`; **mdelay(5)**; clear.
- **NO trimming writes at all** — U-Boot enumerates with trimming at HW default.
- VBUS-valid + width are set **before** the single soft-reset.

### Where the kernel driver differs (the live hypothesis for next session)

`phy-sprd-usb2.c` splits the bring-up across phy-ops: `init` (refclk, width,
databus, trimming, soft-reset), `power_on` (clear ISO_SW + PS_PD), and
`set_mode(DEVICE)` sets **VBUS-valid + VBUSVLDEXT**. Suspicion: the musb glue's
`sprd_otg_switch_set(DEVICE)` board hack may bypass `phy_set_mode`, so
`set_mode(DEVICE)` (hence VBUS-valid/VBUSVLDEXT) **may never run** — or runs at
the wrong time vs `init`'s soft-reset, which would reset the PHY *after*
VBUS-valid was set. U-Boot proves VBUS-valid must be latched *before* the reset.

**Instrumentation is in place** (uncommitted, in the working tree): `dev_info`
in `init` / `power_on` / `set_mode` (prints `hsphy: init|power_on|set_mode <N>`).
`usb-gadget-diag.txt`'s dmesg grep captures `hsphy`. **NEXT SESSION: read that
log first.** Map `set_mode <N>` against `enum phy_mode` (`PHY_MODE_USB_DEVICE`)
in-tree; if the DEVICE set_mode never fires, or `init` runs after it, the fix is
to move the VBUS-valid + VBUSVLDEXT writes (and ideally the whole U-Boot
sequence: ANA_EB, VBUS-valid, width, THEN soft-reset, no trimming) into `init`
so it always runs and the reset comes last.

Debug scaffolding for all this is gated on the `rgdebug` cmdline token
(`build_sdcard_debian.sh`): persistent journal + 10s `debug-flush.service`,
`usb-gadget-diag.service` (→ `/var/log/usb-gadget-diag.txt`), and
`systemd.log_level=info log_target=console show_status=yes loglevel=4`. Strip
the `rgdebug` tokens for a production image.

### 2026-07-05 (cont.) — hsphy log READ: root cause is reset-vs-power ORDERING

The instrumented `hsphy` log finally captured a cold-boot + late-plug ordering
(`usb-gadget-diag.txt`, last block):

```
[  6.538916] hsphy: init        <- soft-reset + trimming + width
[  6.569938] hsphy: set_mode 1  (host)
[  6.571425] hsphy: set_mode 6  (device)  VBUS-valid + VBUSVLDEXT
[ 33.395216] hsphy: power_on    <- ISO_SW + PS_PD cleared (analog powered up)
[ 33.395246] hsphy: set_mode 6  (device)
```

**Root cause (confirmed, not hypothesised): `init()`'s soft-reset pulses a
powered-DOWN PHY.** `power_on()` is what clears ISO_SW/PS_PD (powers the analog
front-end), and on a cold boot that does not run until the cable plug at t=33s —
27s *after* `init()` already did its reset. `power_on()` never re-did the reset,
so the analog came up un-reset and EP0 answered garbage → SET_ADDRESS -71. This
also explains why *every* trimming value gave byte-identical dmesg: trimming was
never the variable; reset ordering was. U-Boot's proven path resets **last, with
the block powered**; ours reset first, isolated, and never again.

**Fix APPLIED (pending HW test):** moved the soft-reset pulse from the end of
`sprd_hsphy_init()` to the end of `sprd_hsphy_power_on()`, after ISO/PD clear.
Trimming/width stay in `init()` (verified to stick while isolated — they
advanced the failure a stage). Net ordering now: power → reset → (set_mode
re-latches VBUS-valid), matching U-Boot. `phy-sprd-usb2.c`.

### 2026-07-05 (cont.) — reset-move ALONE failed; replicating full U-Boot init in power_on

HW-tested the "move soft-reset to power_on" change: **still -71** (descriptor
read AND setup address, host device #50-53, `unable to enumerate`). Two things
learned:

1. The reset move was **backwards ordering** — it reset *before* VBUS-valid
   (set_mode re-asserts VBUS-valid only after power_on), but U-Boot latches
   VBUS-valid + width BEFORE the reset.
2. **User: the working boot was android/cboot U-Boot**, i.e. the enumerating
   path was U-Boot's own `usb_phy_init()`, not just "VBUS present." So the real
   target is byte-for-byte parity with that init.

Traced `src/u-boot/drivers/usb/musb-new/sharkl5pro_usb_phy.c` `usb_phy_init()` —
exact order: (1) `APB_EB1 |= USB_EB | **ANA_EB**` [analog-block clock — our
kernel PHY driver NEVER enabled this; brand-new delta]; (2) VBUS-valid +
VBUSVLDEXT; (3) UTMI width + DATABUS16_8; (4) soft-reset **5ms, last**; NO
trimming.

**Fix APPLIED (pending HW test):** rewrote `sprd_hsphy_power_on()` to replicate
that sequence verbatim after the ISO/PD un-isolate (so it runs with the analog
powered, which on a cold boot only happens at plug). Added `apb_eb1` (0x0004) +
`BIT_AON_APB_ANA_EB` (BIT12) to the driver. Reset delay dropped 20-30ms → 5ms to
match. init()'s trimming left in place for now (U-Boot uses none; revisit if this
still fails). `phy-sprd-usb2.c`. The **ANA_EB analog clock** is the leading
suspect — nothing else in our USB path enabled it.

### 2026-07-06 — A/B PROOF: same kernel, U-Boot path is the variable

User rigged U-Boot to fall through the extlinux path (rename kernel Image) but
pivot boot_a→mmcblk0p2: on the **android/boot_a U-Boot bringup** the gadget
serial **enumerated** (initramfs recovery banner reached the host; switch_root
itself failed, irrelevant); on the **extlinux path** the *same kernel* -71s.
**Conclusion: the enumeration-critical state is what U-Boot's android path leaves
in HW, not anything in kernel USB bringup.** The kernel ANA_EB/power_on
replication (above) did NOT fix the extlinux path.

Traced the android path's U-Boot init: `udc_power_on()` → `usb_startup()`
(sprd_musb2_driver.c) = `usb_enable_module` (OTG_UTMI_EB, kernel already clocks
via DT) + `usb_ldo_switch` (vddusb33, on in both) + `usb_phy_init()` (the
sharkl5pro sequence we already mirror). Register-wise usb_startup adds nothing new
— so the delta is a *residual register bit* one path sets and the other/our kernel
doesn't. Note kernel phy-op order is fine (`sprd.c` sprd_otg_switch_set(DEVICE):
power_on → set_mode → musb_start → D+ pullup), so our reset is NOT mid-enum.

**Observability solved (was the blocker):** failing extlinux boot has no serial,
boot_a wedges at switch_root — but the **initramfs `init` runs in BOTH** and
`console=tty0` (screen) is up. Added a `rgusbdump`-gated register dump to
`src/initramfs/overlay/init` (busybox `devmem`, `CONFIG_DEVMEM=y`): prints
APB_EB1/APB_RST1/CGM_REG1/OTG_PHY_TEST/OTG_PHY_CTRL + ANLG UTMI_CTL1/CTL2/PD/
TRIMMING/PLL/REG_SEL to the screen, holds 12s. **NEXT: add `rgusbdump` to cmdline,
boot both paths, photograph screen, diff — the differing bit is the fix.**

### 2026-07-06 (cont.) — first reg dump was blind on the analog block; retimed

First `rgusbdump` capture (working boot_a, `usb-dump-yes-serial.log`): AON regs
read fine and sane — `APB_EB1=0x001FBDF7` (ANA_EB/bit12 SET), `CGM_REG1=0x0023DEAB`
(OTG_REF/bit12 + DPHY_REF/bit10 SET), `OTG_PHY_TEST=0x01000000` (VBUS_VALID/bit24
SET), `OTG_PHY_CTRL=0x4000000A` (WIDTH/bit30 + IDDIG/bit3 SET) — but **every
ANLG_PHY_G2 reg (UTMI_CTL1/CTL2/PD/TRIMMING/PLL/REG_SEL) read 0x00000000**, and
the failing path matched. Addresses are correct (hsphy = `phy@100` under
`anlg_phy_g2_regs@323b0000` +ranges → 0x323b0100). Root cause of the all-zero:
**the dump ran before the `role=device` assert**, so `phy_power_on` (un-isolate)
hadn't run and the analog block was still powered down → reads 0 in both paths,
hiding the diff. Note TRIMMING reading 0 is consistent with U-Boot doing no
trimming.

Fix: moved the dump to AFTER the role=device assert + `sleep 3`, so the analog
PHY is live during the enumeration attempt. Re-capture both paths.

### 2026-07-06 — ROOT CAUSE FOUND: PHY driver analog base off by 0x100 (+ reg swap)

The live regmap dump (working boot_a, via `dummy-syscon@...323b0000/registers`)
showed the real, configured USB PHY registers at **syscon offset 0x58**:
`0058: 1c010000` = UTMI_CTL1 with DATABUS16_8(bit28)+VBUSVLDEXT(bit16) set, and
`0064: 00cd1ec0` = TRIMMING (eye). But the kernel's dump of 0x158/0x164 (where the
**driver** writes) read all-zero. Cause: the hsphy DT node is `phy@100`
(`reg=<0x100 0x2000>`) under `anlg_phy_g2_regs@323b0000`, so
`devm_platform_get_and_ioremap_resource` gave the driver base **0x323b0100**, and
its data offsets (UTMI_CTL1=0x58 etc., which are meant to be relative to the
syscon base 0x323b0000 per vendor `anlg_phy_g2.h`, `CTL_BASE_ANLG_PHY_G2 +0x58`)
then landed **0x100 too high**. So every analog write (VBUSVLDEXT, DATABUS16_8,
ISO_SW, PS_PD, trimming) missed the real registers. The gadget only ever
enumerated when U-Boot's android/boot_a `usb_phy_init()` had already programmed
0x323b0058 -- exactly the A/B result. Corollary: **all prior trimming experiments
were writing to the wrong register** (0x323b0160), which is why "no trimming value
crossed SET_ADDRESS."

Second bug found in the same table: `utmi_ctl2_reg`/`trimming_reg` were **swapped**
(0x64/0x60; vendor truth UTMI_CTL2=0x60, TRIMMING=0x64).

**FIX APPLIED (`phy-sprd-usb2.c`, pending HW test):** read `ana_regs` from the
parent anlg_phy_g2 syscon via `syscon_node_to_regmap(dev->of_node->parent)`
(base 0x323b0000, mirrors how aon_apb is obtained, avoids the ioremap resource
conflict with `mpll1@0`) instead of ioremapping `phy@100`; and swapped
utmi_ctl2/trimming offsets to vendor-correct. No DT change needed. Removed the now
-unused `regmap_config`/`base`. The `power_on` U-Boot-sequence scaffolding from the
prior round now hits correct registers -- keep for the first test, trim later if
redundant.

### 2026-07-06 — CONFIRMED FIXED ON HARDWARE ✅

The 0x100 base fix works on a cold extlinux boot: host enumerates
`idVendor=0525 idProduct=a4a7 "Gadget Serial v2.4"` → `cdc_acm ... ttyACM0`, no
U-Boot/android crutch. The -71 saga is CLOSED; root cause was the driver writing
analog PHY regs 0x100 too high (see prior entry), nothing to do with trimming,
VBUS ordering, ANA_EB, or reset timing.

Remaining polish (NOT blocking, next session):
- Over `picocom /dev/ttyACM0 -b 115200`, every keystroke registers as `y`
  (input garbled). Likely the serial-getty/agetty drop-in
  (`-o "-p -- \\u" --autologin root ... vt220`) or a line-discipline/baud quirk on
  ttyGS0, not the PHY. Start at `serial-getty@ttyGS0` override + agetty flags.
- Strip debug scaffolding from `src/initramfs/overlay/init` (rgusbdump reg dump,
  the respawning interactive gadget shell) and revisit whether the `power_on`
  U-Boot-sequence replication in `phy-sprd-usb2.c` is still needed now that the
  register base is correct (may revert to simpler mainline power_on).

### 2026-07-06 (cont.) — input garble diagnosed: agetty baud-cycling, not the PHY

Host picocom output tracked the baud (garble was `y` at 115200, `ttyGS0` banner
fragments like `S0` at 9600). On a CDC-ACM gadget the baud is advisory and bulk
transfers are byte-exact, so a baud-sensitive symptom is **agetty**, not the wire:
the running getty was in multi-baud + parity-detect mode (baud list + no working
autologin → cycles baud and re-prints the `%I`/`\l` banner; parity auto-detect
garbles the login-name echo).

**Fix applied** (`tools/scripts/build_sdcard_debian.sh` + `src/rootfs-build/make-image.sh`):
serial-getty `override.conf` now `agetty --autologin root --noclear 115200 %I $TERM`
— single fixed baud, dropped `--keep-baud` and the comma baud list, dropped the
`-o '-p -- \u'` issue string. **Pending HW test** (blocked on a USB-C↔C cable for a
host keyboard; verify with `picocom -b 115200 /dev/ttyACM0`). If garble persists,
capture the *booted* image's live getty with `systemctl show -p ExecStart
serial-getty@ttyGS0` + `ps -ef | grep agetty` to confirm the drop-in actually
applied, and raw-A/B on tty1 with `stty -F /dev/ttyGS0 raw -echo; cat /dev/ttyGS0 | xxd`.

### 2026-07-06 (cont.) — garble is NOT agetty: HS PHY eye (step-2 trimming) suspected

The initramfs recovery path (raw kernel/`sh` writes straight to `/dev/ttyGS0`, no
getty) garbles **identically** to the systemd getty path — so agetty is ruled out
as the cause (the getty hardening stays as correctness cleanup). `serial.log`
(deliberately-failed init) shows the tell: **repeated substrings**
(`lookuookuooku`, `evevev`, `torytory`), the signature of CRC-retried / duplicated
HS bulk transactions, i.e. a marginal **high-speed PHY eye** — not random bit
flips, not config.

Root-cause chain: all the `phy-sprd-usb2.c` trimming experiments were "validated"
while writes landed 0x100 too high (the base bug) — they never touched the PHY. Now
that the base is fixed, they ALL fire on the real register for the first time,
including the home-grown **step 2** (`TFHSRES=0x1f`, `TUNEOTG=0`) that the vendor
sharkl5Pro BSP does NOT do. `TFHSRES` is HS termination impedance; a wrong value
corrupts the eye → duplicated bulk bytes while the forgiving control-transfer
enumeration still succeeds.

**First fix (step-2 removal) HW-tested: still garbled**, and forcing high-speed
didn't change it either. So the remaining step-1 `TUNEHSAMP=3`/`TFREGRES=0x14` are
suspect too — same provenance (never reached the PHY before the base fix). The only
config known to enumerate cleanly on this silicon is U-Boot's sharkl5pro
`usb_phy_init()`, which writes **NO trimming at all**.

**Fix APPLIED (pending HW test):** removed ALL trimming from `sprd_hsphy_init()` —
match U-Boot, leave the eye at silicon default. `phy-sprd-usb2.c`. (TUNEHSAMP/
TFREGRES macros kept for reference only.) If this clears the garble, trimming was
the whole story. If not, next suspects: UTMI width/DATABUS16_8 vs the host's actual
mode, or the musb FIFO/endpoint (maxpacket) config — instrument a bulk loopback and
diff against U-Boot's register state.

### 2026-07-06 — CONFIRMED CLEAN ON HARDWARE ✅ (USB serial console DONE)

Removing all trimming fixed the garble: `root@rgrotate:~#` shell over
`/dev/ttyACM0` reads and writes cleanly, both directions. Root cause was the
never-validated HS trimming (TUNEHSAMP/TFREGRES/TFHSRES) finally landing on the
real TRIMMING register after the 0x100 base fix and corrupting the HS eye — U-Boot's
no-trimming profile is the correct config for this silicon. `sprd_hsphy_init()` now
does clock gates + width + one soft-reset, no trimming.

Cosmetic leftover fixed: agetty printed `/etc/issue` and a few banner bytes raced
into the shell stdin at login (`-bash: Debian: command not found`). Added
`--noissue` (autologin needs no banner) to the serial-getty override in both build
scripts. The whole -71 + garble saga is CLOSED; USB gadget console works on a cold
extlinux boot with a clean autologin shell.

## Exact failure signature (host dmesg, power-button boot + late plug)

```
usb 1-2: new high-speed USB device number N using xhci_hcd
usb 1-2: device descriptor read/64, error -71
usb 1-2: device descriptor read/64, error -71
usb usb1-port2: attempt power cycle
usb 1-2: Device not responding to setup address.
usb 1-2: device not accepting address N, error -71
... repeats ...
```

The device **is** seen and negotiates high-speed; only EP0 data fails. This is a
gadget/PHY-side EP0/signal problem, not a missing-connect-edge problem.

## What we established (durable facts)

- **The connect edge is NOT the issue.** Each "new high-speed USB device number
  N" above is a fresh edge; the host clearly sees the gadget connect. So a role
  re-assert alone cannot fix it.
- **`state` *does* leave `configured` on a real unplug** (→ `default`), verified
  with a transient `systemd-run` logger that survives the carrier drop
  (contiguous timestamps across the unplug). So `/sys/class/udc/*/state` is a
  valid "host present & enumerated" signal despite the PHY force-asserting VBUS.
- **A role toggle must be detached from the ttyGS0 session.** `echo none > role`
  drops the gadget carrier; a job parented to the gadget getty gets SIGHUP and
  dies after `none` but before `device`, wedging the device with role=NONE / PHY
  off (unreachable until power-cycle). A systemd service is naturally detached.
- **USB ref clocks are ON in the working state.** `CGM_REG1` (AON-APB
  `0x327d0138`) reads `0x0023dfab` after a USB-plug boot — both
  `CGM_OTG_REF_EN (0x1000)` and `CGM_DPHY_REF_EN (0x400)` set — yet mainline's
  `phy-sprd-usb2.c` never writes `CGM_REG1`. So U-Boot sets them on the USB-plug
  path. (See "Attempts that did NOT fix it" #3 — adding this to the kernel did
  not resolve -71, so it is necessary-looking parity but not sufficient/the
  cause.)
- **`vddldo0` is a red herring for USB.** Stock marks `LDO_VDDLDO0`
  `regulator-always-on`; mainline does not, so since we dropped
  `regulator_ignore_unused` it now shows "vddldo0: disabling" on the fbcon. But
  `vddldo0` is **disabled in the working USB-plug boot too** (and `vddusb33` is
  enabled in both), so it is not the USB differentiator. (Marking it always-on
  to match stock may still be worth doing for other subsystems.)

## Attempts that did NOT fix it

1. **Role re-assert at boot (one-shot, initramfs + `usb-device-role.service`).**
   This is the long-standing assert-`device`-once approach. Works on USB-plug
   boot (host present at assert); on power-button boot it asserts into the void
   and a later plug -71s.
2. **State-driven role re-toggle daemon** (`/usr/local/bin/usb-gadget-reconnect`,
   `usb-gadget-reconnect.service`): loops, and whenever
   `udc state != configured` cycles `none→device` to present a fresh D+ edge,
   leaving an active (configured) session untouched. Gives clean edges, but each
   edge still -71s on cold boot because EP0 itself is dead. **Kept installed** —
   it is the right mechanism for the late-plug edge and will be needed *together
   with* whatever fixes EP0.
3. **Userspace `devmemn` poke of `CGM_OTG_REF_EN` before the role assert** (added
   to the daemon startup): no effect. Expected in hindsight — the kernel already
   ran `phy_init`/`musb_start` with the ref clock off, so latching it on after
   boot doesn't recover the controller.
4. **Kernel PHY-driver fix (committed-in-tree change, build flashed to boot_a):**
   in `drivers/phy/phy-sprd-usb2.c` `sprd_hsphy_init()`, before `musb_start`:
   enable `CGM_OTG_REF_EN | CGM_DPHY_REF_EN` in `CGM_REG1` (0x0138) and
   soft-reset the PHY/UTMI via `APB_RST1` (0x0010, bits `OTG_PHY_SOFT_RST 0x200`
   `OTG_UTMI_SOFT_RST 0x100`, 20–30ms pulse) — mirroring the vendor BSP
   `phy-sprd-sharkl5Pro.c` init delta. **Still -71 on cold boot.** The change is
   correct vendor parity and does not break the USB-plug path, so it was left in
   place, but it is not the root cause.

## Vendor reference

`vendor/android-kernel-ums512/drivers/usb/phy/phy-sprd-sharkl5Pro.c` is the
register-level reference. Its `sprd_hsphy_init` does, beyond mainline: enable
`OTG_UTMI_EB`, enable `CGM_OTG_REF_EN | CGM_DPHY_REF_EN`, clear ISO/PD, force
VBUS valid, set UTMI width + DATABUS16_8, set `TUNEHSAMP`/`TFREGRES` trimming
(mainline writes one hardcoded `DEFAULT_EYE_PATTERN=0x04f3d1c0` instead), and
soft-reset the core. Of these, the still-unexplored deltas are the **HS
trimming** (`TUNEHSAMP_2_6MA`, `TFREGRES_TUNE_VALUE`) — a wrong eye/amplitude
would corrupt HS data and produce exactly this EP0 -71 — and the **charger/VBUS
notifier** path (`sprd_hsphy_vbus_notify`) which the vendor wires to the PMIC.

## Next ideas (when we return)

- **Regulator/DTS completeness (user's lead).** Audit which rails the stock DT
  keeps up (`regulator-always-on`) that mainline drops; bring up the SC2730
  charger/typec (`sprd,sc2730-pd`, currently `disabled`) so real VBUS/CC events
  exist. May make the issue moot.
- **HS trimming parity.** Replace the single `DEFAULT_EYE_PATTERN` write with the
  vendor's explicit `TUNEHSAMP`/`TFREGRES` field programming and compare a cold
  boot. Cheap to try; strong candidate for an EP0 -71.
- **Observability on the failing boot.** We have no console on a cold boot
  (USB is the console). Instrument a boot-time service to dump USB PHY/musb regs
  to `/run` (like the udclog trick) so the failing-state registers can be diffed
  against the known-good capture without a serial line.

## Register map (sharkl5pro / ums512, for `devmemn` probing)

- AON-APB base `0x327d0000`: `CGM_REG1 0x0138` (OTG_REF `0x1000`, DPHY_REF
  `0x400`); `APB_RST1 0x0010` (OTG_PHY_SOFT_RST `0x200`, OTG_UTMI_SOFT_RST
  `0x100`); `OTG_PHY_TEST 0x0204` (VBUS_VALID_PHYREG `BIT24`); `OTG_PHY_CTRL
  0x0208` (UTMI_WIDTH_SEL `0x40000000`, IDDIG `BIT3`).
- musb controller `0x5fff0000` (size 0x2000); analog PHY (anlg_phy_g2)
  `0x323b0100` + driver offsets (utmi_ctl1 `0x58`, pd `0x5c`, trimming `0x60`,
  utmi_ctl2 `0x64`, pll `0x70`, reg_sel_cfg `0x74`).
- The CDC-ACM reconnect daemon: `/usr/local/bin/usb-gadget-reconnect` +
  `usb-gadget-reconnect.service` on the eMMC Debian rootfs (not yet folded into
  `src/rootfs-build/make-image.sh`).
