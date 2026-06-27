# USB gadget console — cold (power-button) boot enumeration — Status and History

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
