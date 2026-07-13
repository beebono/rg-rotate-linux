# Bluetooth bring-up scoping (Marlin3-Lite / SC2355 over SDIO)

Status: **COMPLETE** — See the WCN port notes in memory (`wcn-bringup-marlin3-port`) and
`DEVICE-BRINGUP.md` for further details.

## TL;DR

BT is a **small** lift because two hard pieces are already solved for us:

1. **Transport foundation** — the `sprdwcn` SDIO bus, `start_marlin()`, firmware
   download, and mchn channels are live (the entire Wi-Fi bring-up). BT just adds
   two more channels (TX **3**, RX **17**) on the same bus.
2. **The vendor HCI init handshake is already implemented in-kernel, mainline-style.**
   The tree ships [`drivers/bluetooth/btsprdsipc.c`](../src/linux-7-1-sprd/drivers/bluetooth/btsprdsipc.c)
   (Otto Pflüger, 2024) which registers a real `hci_dev` and performs the exact
   Unisoc pskey/RF/enable vendor-command sequence. Its **only** mismatch for us is
   the transport: it speaks rpmsg/SIPC (the SoC-integrated chip), not our external
   SDIO Marlin3. This is the *same* situation as Wi-Fi (mainline core spoke SIPC;
   we wrote the SDIO backend).

**Consequence:** we do **not** need the Android `libbt-vendor` userspace HAL, we do
**not** need `hciattach`/a custom init tool, and we do **not** need to reverse the
pskey VSC format. BlueZ gets a native `hci0` directly. The lift collapses to
"port one small kernel driver's transport from rpmsg → sprdwcn SDIO, and stage two
config blobs."

Estimate: **~2–4 focused days** to a scanning/pairing `hci0`, risk concentrated in
the SDIO framing/alignment detail (see Risks), not in HCI init or userspace.

## What btsprdsipc.c gives us (reuse verbatim)

All of this is transport-agnostic and ports over unchanged:

- `hci_alloc_dev`/`hci_register_dev` → native `hci0`, `manufacturer = 1855`
  (Unisoc), `set_bdaddr` hook, `HCI_QUIRK_USE_BDADDR_PROPERTY`.
- `h4_recv_buf` + `sprd_recv_pkts[]` (ACL/SCO/EVENT) RX reassembly.
- **The init sequence** (`btsprdsipc_set_bdaddr`, must be the first command sent):
  1. patch BD addr into `pskey_cfg + 20`, send VSC **`0xfca0`** (pskey, len = blob size)
  2. send VSC **`0xfca2`** (RF config)
  3. send VSC **`0xfca1`** with `{0, 9, 1}` (enable)
  4. send `HCI_OP_RESET`
- `request_firmware("sprd/bt_config_pskey.bin")` + `"sprd/bt_config_rf.bin"`.

## What we write (the delta)

A sibling driver — call it `btsprdsdio.c` — that keeps the `hci_dev` setup,
`sprd_recv_pkts`, and the `set_bdaddr` init sequence **identical**, and swaps only:

| Concern | btsprdsipc (have) | btsprdsdio (write) |
|---|---|---|
| Bind | `rpmsg_driver`, compat `sprd,bluetooth-sipc` | `platform_driver`, compat **`sprd,mtty`** (the DT BT child) |
| Power | (chip already up via remoteproc) | `start_marlin(MARLIN_BLUETOOTH)` on open / `stop_marlin` on close |
| TX (`hdev->send`) | `rpmsg_send(ept, …)` | `sprdwcn_bus_list_alloc` → set buf → `sprdwcn_bus_push_list(BT_TX_CHANNEL=3, …)` |
| RX | rpmsg `.callback` → `h4_recv_buf` | mchn RX op on `BT_RX_CHANNEL=17` → `h4_recv_buf` (same call) |
| Channels | n/a | `sprdwcn_bus_chn_init(&bt_tx_ops/&bt_rx_ops)` in probe |

This is precisely the shape of the vendor `wcn/bluetooth/driver/tty-sdio/tty.c`
(~828 LOC) — but we take the *channel/bus plumbing* from that vendor file and the
*HCI/hci_dev logic* from mainline btsprdsipc, rather than porting the vendor tty
device (`ttyBT`) + a userspace HAL. Net driver size: ~300–400 LOC.

Reference bus/marlin call sites in the vendor tty-sdio driver:
- channels: `tty.h` `BT_TX_CHANNEL 3`, `BT_RX_CHANNEL 17`, `BT_TX_INOUT 1`, `BT_RX_INOUT 0`
- power: `start_marlin(MARLIN_BLUETOOTH)` / `stop_marlin(MARLIN_BLUETOOTH)`
- TX: `sprdwcn_bus_list_alloc` / `sprdwcn_bus_push_list` / `sprdwcn_bus_list_free`
- probe: `sprdwcn_bus_chn_init(&bt_rx_ops)` / `sprdwcn_bus_chn_init(&bt_tx_ops)`, compat `sprd,mtty`

## Do we need the bt_configure_*.ini files? — YES

They are **not** self-applied by firmware and **not** read by any kernel driver
(the vendor tty-sdio driver never calls `request_firmware`/touches the ini; it is a
dumb pipe). The `wcnmodem.bin` CP2 image boots BT with *unprovisioned* parameters —
the pskey table is the device-specific provisioning the CP2 expects at HCI-init
time (BD addr, `feature_set`, `device_class`, `comp_id`, log levels), and
`bt_configure_rf.ini` is the RF calibration (gain/power tables). Without them: link
enumerates but has a null/garbage BD addr, wrong TX power, flaky/dead scanning.

Stock btsprdsipc consumes them as **packed binary** blobs
(`sprd/bt_config_{pskey,rf}.bin`). **We deliberately parse the INI in-kernel
instead**, for parity with the Wi-Fi path — the Wi-Fi bring-up chose an in-kernel
INI parser (`unisoc/hw_param.c` / `sc23xx_load_hw_param`) precisely to avoid an
offline encoder and a separate `.bin` staging step. Same reasoning here; keep both
subsystems' config staging uniform (ship the vendor `.ini` verbatim, parse at
probe).

### The INI is self-describing — no name-table needed

Unlike the Wi-Fi config (which needed the ported `wifi_conf_t` struct + a name
table), the BT pskey/rf ini carries its own schema in the `#[x.yy]__/L=N` comment
lines. The packing rule is uniform:

> **`bytes_per_token = L / token_count`, emit each token little-endian at that
> width, entries in declaration order.**

| Entry | `/L=` | tokens | bytes/token |
|---|---|---|---|
| `device_class = 0x001F00` | 4 | 1 | 4 (LE) |
| `feature_set = 0xBF, 0xFF, …` | 16 | 16 | 1 |
| `comp_id = 0x01EC` | 2 | 1 | 2 (LE) |
| `bt_coex_threshold` (8 vals) | 16 | 8 | 2 (LE) |

Confirmed consistent with btsprdsipc's `pskey_cfg + 20` bdaddr patch
(`device_class[4] + feature_set[16] = 20 = device_addr`). pskey totals
`[Total Length=160]`, rf `[Total Length=252]`.

**Parser (~60–80 LOC, reuse the `hw_param.c` line-tokeniser style):**
`request_firmware("sprd/bt_configure_pskey.ini")` → walk lines: a `/L=N` comment
sets the current field width; following `name = …` value line(s) contribute tokens
(a couple of rf fields — `g_BRChannelpwrvalue`/`g_EDRChannelpwrvalue` — place two
value lines under one `/L=32`, so accumulate until the field's byte count is
filled) → append LE bytes → hand the buffer to the same `0xfca0`/`0xfca2` VSCs.
The init sequence is unchanged; only the *source* of the bytes moves in-kernel, and
the offset-20 bdaddr patch still lands.

- Variants `_aa` / base / `.xpe` (chip-id / SKU select, same as Wi-Fi) — pick the
  matching one; they differ only in cali values.
- Source inis in-repo at
  `device/stock/vendor_extracted/firmware/wcn/bt_configure_{pskey,rf}{,_aa,.xpe}.ini`;
  stage the `.ini` verbatim into initramfs `/lib/firmware/sprd/`.
- **Robustness:** assert the summed section bytes == the header `[Total Length=…]`
  so a malformed/variant ini fails loud instead of sending a short VSC. Relies on
  the `/L=` comments being present (true in all three variants).
- BD addr in pskey is a placeholder — the driver overwrites offset 20 via
  `set_bdaddr`; feed a random/persistent LAA (Wi-Fi `eth_random_addr` precedent) or
  wire `HCI_QUIRK_USE_BDADDR_PROPERTY` from DT `local-bd-address`.

## DT

Add the `sprd,mtty` child under the existing marlin node (the node is already
present from Wi-Fi bring-up). No new supplies/GPIOs — BT shares the WCN combo
power/reset the marlin core already drives.

## Work items & order

1. **In-kernel INI parser** (~60–80 LOC, `/L=`-driven, LE, total-length assert) +
   stage the vendor `.ini` verbatim in initramfs `/lib/firmware/sprd/`. Verify
   byte layout against the `+20` bdaddr anchor. (~0.5 day)
2. **`btsprdsdio.c`**: fork btsprdsipc, swap transport to sprdwcn SDIO (channels
   3/17, `start/stop_marlin`, push_list/mchn RX), bind `sprd,mtty`, feed the
   parser's buffer to the `0xfca0`/`0xfca2` VSCs. Wire Kconfig/Makefile. (~1 day)
3. **DT** `sprd,mtty` child + defconfig. (~0.5 day)
4. **Bring-up**: `hci0` appears → `set_bdaddr` init sequence ACKs → `hciconfig hci0 up`
   → `hcitool scan` / LE scan → pair. (~1 day, plus framing debug)

## Risks (where the days actually go)

- **SDIO framing/alignment.** btsprdsipc's TX pads to **8-byte alignment** (a SIPC
  requirement) and prepends the 1-byte H4 packet type. The SDIO path has its own
  framing: the vendor tty-sdio uses `alignment/sitm.c` for HCI packet
  segmentation/reassembly, and sdiohal fills its own 4-byte public header (`puh`)
  per buffer (exactly as in the Wi-Fi `unisoc/sdio.c` backend — leave
  `SDIOHAL_PUB_HEAD_RSV` headroom, strip on RX). Getting the H4-type / alignment /
  puh layering right on TX+RX is the main unknown. Mirror the Wi-Fi SDIO backend's
  headroom/strip discipline.
- **RX callback context.** mchn RX delivers via `pop_link` on the bus rx thread;
  `h4_recv_buf` + `hci_recv_frame` must be called in a safe context (the vendor
  driver uses an `SPRDBT_RX_QUEUE` workqueue). Reuse that pattern.
- **First-command ordering.** btsprdsipc notes the pskey VSC *must* be the first
  command to the controller (that is why init lives in `set_bdaddr`, not `setup`).
  Preserve that ordering on the SDIO path.
- **BD address source.** GET_INFO-style MAC is absent for BT too; use a
  random/persistent LAA (Wi-Fi precedent) or DT `local-bd-address`.

## Why this is smaller than the Wi-Fi lift

No cfg80211, no credit/color flow-control engine (the thing that ate most of the
Wi-Fi data-path effort), no A-MSDU/BA-reorder. HCI flow control is intrinsic to the
protocol and handled by BlueZ. The kernel driver is a thin HCI-over-mchn shim, and
the vendor init handshake is already written. The only genuinely new code is the
transport glue and the ini→bin marshaller.
