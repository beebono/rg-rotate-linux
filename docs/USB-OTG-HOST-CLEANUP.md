# USB OTG / Host Mode — Cleanup & Implementation Scoping

Status: **IMPLEMENTED** (automatic dual-role OTG working on hardware).
Companion to [WHAT-HAS-BEEN-TRIED-USB.md](WHAT-HAS-BEEN-TRIED-USB.md)
(gadget-mode -71 saga, now closed) and the USB line in
[DEVICE-BRINGUP.md](../DEVICE-BRINGUP.md). The scoping analysis below is kept
as the historical record; the section immediately following describes what
actually shipped.

## What shipped

Rather than add automatic role detection on top of the manual role switch, the
final solution brings up the **PMIC Type-C port manager** (`sc27xx_pd`, the
`sc2730-pd` block) so CC detection selects host/device automatically — the
"proper" Type-C path. Committed as one change in the `linux-7-1-sprd` submodule
("usb: automatic dual-role OTG via PMIC Type-C CC detection").

- **VBUS source.** There is no discrete 5V regulator; host VBUS is the AW32257
  (`bq2415x`) charger's OTG boost. `bq2415x_charger.c` gained a `usb-otg-vbus`
  regulator provider (enable/disable → charger BOOST/OFF), built in (`m`→`y`)
  so it exists before the built-in TCPM resolves `vbus-supply`.
- **TCPM.** `&pmic_typec_pd` enabled with a `usb-c-connector` OF-graphed to
  `&usb`'s role switch; `vbus-supply` lives on the PD node (TCPM owns VBUS
  exclusively). Connector is `pd-disable` — CC role detection only, no PD
  contracts (avoids the source/sink-pdo requirement).
- **`sc27xx_pd.c` fixes:** vconn via `get_optional` (no VCONN switch on this
  board, absent supply must not `-EINVAL` the exclusive get); as source, report
  `vbus_present` from commanded state (the PMIC VBUS_OK comparator never senses
  the external boost, so polling it timed out `-110` and stalled the SRC state
  machine); fixed a copy-paste `is_enabled(vbus)`→`vconn`.
- **`musb/sprd.c`:** optional `vbus` supply driven from the role-switch state
  machine, for non-TCPM boards; dormant here since VBUS lives on the PD node.
- **Cleanup:** the three userspace forced-`device` oneshots (below) are removed
  — they fought the TCPM. The gadget console still comes up when plugged into a
  host (CC selects device via `try-power-role = "sink"`). The inert
  `linux,extcon-usb-gpio` node and its `&usb`/`&hsphy`/`charger` references were
  dropped: nothing consumed it (the PHY force-asserts VBUS-valid in hardware),
  confirmed by removal having no effect.

## TL;DR

"Forced gadget mode" is **not** a kernel or DT restriction — it's three
near-identical systemd/initramfs oneshots that write `device` to
`/sys/class/usb_role/*/role` and never write `host`. The kernel already has
everything needed for real dual-role operation: DT says `dr_mode = "otg"`,
the config builds `USB_MUSB_DUAL_ROLE` + `USB_ROLE_SWITCH`, and the mainline
musb glue driver (`drivers/usb/musb/sprd.c`, written for this project) already
implements a correct host/device/none state machine behind the standard
`usb_role_switch` class. What's missing is **automatic role detection**
(ID-pin/VBUS/CC) — stock Android never had this either (stock hardcodes
`dr-mode = "peripheral"`), so this is genuinely new ground, not a regression.

## Current state

### Where gadget mode is forced (userspace, not kernel)

Three copies of the same one-liner, none of them ever selecting `host`:

- `src/initramfs/overlay/init:44-50` — early boot, before rootfs:
  ```sh
  for r in /sys/class/usb_role/*/role; do
      [ -e "$r" ] || continue
      echo device > "$r" 2>/dev/null
  done
  ```
- `src/rootfs-build/make-image.sh:49-63` — installs
  `usb-device-role.service` (`Before=sysinit.target`) into the production
  eMMC image, same one-liner.
- `tools/scripts/build_sdcard_debian.sh:162-176` — identical service for the
  SD-card/extlinux debug image.

There's also an in-flight, not-yet-committed `usb-gadget-reconnect.service`
(mentioned in `WHAT-HAS-BEEN-TRIED-USB.md`, not yet folded into
`make-image.sh`) that watches `/sys/class/udc/*/state` and cycles
`none → device` on late cable-plug. It never touches `host` either, and any
role-switch redesign needs to reconcile with it (see below).

The gadget function itself is the legacy `g_serial` driver
(`CONFIG_USB_G_SERIAL=y`), not a configfs-composed gadget, even though
`CONFIG_USB_CONFIGFS` and the individual function modules are built.

### Device tree

`src/linux-7-1-sprd/arch/arm64/boot/dts/sprd/ums512-rg-rotate.dts:680-688`:
```dts
&hsphy {
    status = "okay";
    phy-supply = <&vddusb33>;
};

&usb {
    status = "okay";
    dr_mode = "otg";
};
```

No `extcon`, `id-gpio`, or `vbus-gpio` property anywhere on `&usb`/`&hsphy`.
The stock (Android) DT (`docs/decomp_stock.dts`) hardcodes
`dr-mode = "peripheral"` on the musb node directly — stock never did
dual-role either. Stock does have a separate top-level `extcon-gpio` node
(`linux,extcon-usb-gpio`, `vbus-gpio` at line ~5618) but it feeds the PMIC's
Type-C/PD block (`sc27xx-pd`) for charger/PD detection only, not the musb
role switch.

The on-PMIC Type-C/PD block (`sc2730-pd`,
`src/linux-7-1-sprd/arch/arm64/boot/dts/sprd/sc2730.dtsi:145-155`) exists in
the SoC dtsi but is `status = "disabled"` and never re-enabled in the board
dts.

### Kernel config

Already correctly built for OTG (`ums512_defconfig` /
`src/linux-7-1-sprd/.config`):
```
CONFIG_USB_MUSB_DUAL_ROLE=y   # USB_MUSB_SPRD Kconfig selects this
CONFIG_USB_ROLE_SWITCH=y
CONFIG_EXTCON_USB_GPIO=y
CONFIG_USB_CONN_GPIO=y
CONFIG_TYPEC=y / TYPEC_TCPM / TYPEC_SC27XX_PD
CONFIG_USB_XHCI_HCD / EHCI_HCD / OHCI_HCD (platform variants) = y
```
Nothing here forces gadget-only; `EXTCON_USB_GPIO` and `USB_CONN_GPIO` are
already built in with no DT consumer wired up.

### Existing driver support (already does the hard part)

`src/linux-7-1-sprd/drivers/usb/musb/sprd.c` (project-authored mainline musb
glue, not a vendor drop-in) registers a real `usb_role_switch`:

- `sprd_otg_switch_set()` — full state machine for `USB_ROLE_HOST` /
  `USB_ROLE_DEVICE` / `USB_ROLE_NONE`, including the SoC-specific quirk
  (comment in source) that VBUS is force-asserted with no session edge, so
  peripheral mode manually starts the controller and asserts a pullup.
- `sprd_otg_switch_init()` registers with `allow_userspace_control = true`
  — this is exactly why the current `echo device > role` oneshots work.
  `echo host > role` is equally reachable today; nothing in the repo has
  ever invoked it.
- `glue->role = USB_ROLE_NONE` at probe — the port does **nothing** until
  something (today: only the userspace oneshots) writes to the role-switch
  sysfs file. No extcon notifier, no GPIO IRQ, no automatic detection of any
  kind is wired into this driver.
- Latent footgun: `sprd_musb_probe()` lines 302-305 silently overrides the
  DT-declared `dr_mode` to host-only or gadget-only if
  `CONFIG_USB_MUSB_HOST`/`CONFIG_USB_MUSB_GADGET` are ever set individually.
  Currently a no-op since dual-role is selected, but worth a guard/comment
  so nobody flips those configs "to simplify" and silently breaks OTG.

`drivers/phy/phy-sprd-usb2.c` has `sprd_hsphy_set_mode()` handling
`PHY_MODE_USB_HOST`/`PHY_MODE_USB_DEVICE` VBUS-valid toggling already; it's
a pure `phy_ops` callee of the glue driver, no changes anticipated there.

## What's actually missing

1. **Automatic role detection.** No ID-pin, VBUS-presence, or CC-based
   signal drives the role switch — everything is manual today. Options,
   roughly in order of effort:
   - a. Keep it fully manual (a debug/dev-mode script or button combo that
     runs `echo host|device > role`). Zero kernel work, doesn't help a
     real end user with a host cable.
   - b. Wire a `linux,extcon-usb-gpio` node against a VBUS or ID GPIO, if
     the hardware exposes one, and hook a `usb_role_switch` consumer via
     `extcon` (standard `extcon-usb-gpio.c` + `usb_role_switch` glue
     already exists in mainline — would need a small consumer shim since
     `sprd.c` doesn't currently register as an extcon consumer).
   - c. Enable the on-PMIC `sc2730-pd` Type-C/PD block and let CC-line
     orientation/role detection drive the switch (most "correct" for a
     Type-C port, but the PMIC block is currently disabled and untested;
     highest effort, needs its own bring-up pass, likely including PD
     negotiation quirks).
   - **Hardware check needed first:** does this board even expose an ID
     pin, or is the connector VBUS-only (i.e. software/PD-negotiated role
     only)? This determines whether (b) is available at all or whether
     (c) is the only automatic path. Worth checking `docs/decomp_stock.dts`
     schematics/pinmux references and/or continuity-testing the physical
     port before committing to an approach.
2. **Testing host mode at all.** Nobody has ever exercised
   `sprd_otg_switch_set()`'s `USB_ROLE_HOST` branch on this hardware. Before
   any detection-automation work, the manual path should be validated:
   flip role to `host` via sysfs with a USB device (flash drive, keyboard)
   attached via an OTG adapter, confirm `xhci`/`ehci`/`ohci` platform
   binds and the device enumerates.
3. **Reconciling the reconnect daemon.** `usb-gadget-reconnect.service`
   (not yet committed to `make-image.sh`) only knows about the gadget
   `none→device` cycle. Any role-switch redesign needs to either extend it
   to be role-aware or scope it strictly to gadget-mode reconnect and leave
   host-mode detection as a separate, independent path.
4. **De-duplicating the forcing logic.** Three near-identical copies of the
   `echo device > role` oneshot exist (initramfs `init`, `make-image.sh`,
   `build_sdcard_debian.sh`). Once real role-detection lands, this should
   collapse to one mechanism (ideally kernel/extcon-driven, with the
   current oneshots either removed or demoted to a fallback for boards/debug
   builds without ID-pin detection).

## Suggested phased plan

1. **Phase 0 (no kernel changes): manual host-mode validation.** Add a
   throwaway debug script (or reuse the existing oneshot pattern with
   `host` instead of `device`) to confirm `sprd_otg_switch_set()`'s host
   path actually enumerates a USB storage device / keyboard end to end.
   This validates the driver work already sitting in `sprd.c` before
   investing in detection automation.
2. **Phase 1: hardware investigation.** Determine whether the physical
   port/connector exposes an ID pin or is VBUS/CC-only. This gates whether
   phase 2 is extcon-GPIO-based or PD/CC-based.
3. **Phase 2a (if ID-pin available): extcon-usb-gpio wiring.** Add the DT
   node, a small consumer to bind it to the existing `usb_role_switch`
   (mainline has generic glue for this pattern; may already work with zero
   `sprd.c` changes if the role-switch is discoverable via the standard
   `usb_role_switch_get()`/`fwnode` graph — needs a spike to confirm).
4. **Phase 2b (if no ID pin): PMIC Type-C/PD bring-up.** Enable
   `sc2730-pd`, bring up basic CC/orientation detection, wire its role
   signal to the switch. Substantially larger scope — separate work item,
   likely its own doc once phase 1 determines it's necessary.
5. **Phase 3: cleanup.** Collapse the three duplicate gadget-forcing
   oneshots into one canonical mechanism; fold `usb-gadget-reconnect.service`
   into `make-image.sh` with role-awareness; add a guard/comment in
   `sprd_musb_probe()` against the config-override footgun.

## Open questions

- Does the rg-rotate handheld's USB-C (or micro-USB?) port physically wire
  an ID pin, or is it VBUS-only? (Blocks phase 1/2 decision.)
- Is there a real end-user use case for host mode (e.g. USB storage/OTG
  keyboard) or is this purely a dev/debug convenience? Affects how much
  effort automatic detection is worth vs. a manual toggle being sufficient.
- Should host-mode switching be exposed to the end user at all (e.g. via a
  settings toggle) or remain a developer-only sysfs poke indefinitely?
