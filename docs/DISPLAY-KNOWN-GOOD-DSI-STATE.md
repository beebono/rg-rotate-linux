# Known-good DSI host register fingerprint (panel visible)

Captured 2026-06-26 over `/dev/ttyACM0` (gadget `0525:a4a7`, kernel
`6.16.0-sprd-ums512+`) while the panel was **visibly showing fbcon** via the
older **U-Boot framebuffer handoff** path (the path we are trying to migrate
*away* from). DSI-host space only (`0x204xxxxx`); DPU space (`0x20300000+`) was
deliberately not read — those reads wedge the device (see CLAUDE.md / WHAT-HAS-BEEN-TRIED.md).

This is the **reference fingerprint of a working display**. Diff the kernel-native
(non-handoff) boot path against this; the failure mode historically reappears as
the data-lane stopstate bits returning (`PHY_STATUS` `0x1f02` → `0x1f32`).

`devmemn <ADDR>` is read-only (a second arg would be a *write* VALUE). All reads
below were address-only.

## Registers

| Reg | Addr | Value | Decode |
|---|---|---|---|
| PHY_STATUS | 0x2040009C | `0x1f02` | PHY_LOCK set; data lanes **out of stopstate** (bits 4,5 clear) → transmitting HS |
| VID_MODE_CFG | 0x20400038 | `0x3f02` | VID_MODE_TYPE=`0b10`=**burst**; all LP_* blanking enables (bits 8–13) set |
| DSI_MODE_CFG | 0x20400018 | `0x0` | **video mode** (bit0 clear; not command mode) |
| PHY_INTERFACE_CTRL | 0x20400078 | `0x7` | SHUTDOWNz · RESET_N · CLK_EN all set → PHY powered, out of reset, clocked |
| PHY_LANE_NUM_CONFIG | 0x204000A4 | `0x1` | **2 data lanes** (value+1) |
| PROTOCOL_INT_STS | 0x20400008 | `0x0` | no protocol/transmit errors latched |
| DPI_VIDEO_FORMAT | 0x20400020 | `0x05` | **RGB888** (not loosely-18) |
| VIDEO_PKT_CONFIG | 0x20400024 | `0x2d0` | **720** px/line, 0 chunks |
| VIDEO_LINE_HBLK_TIME | 0x20400028 | `0x0003005d` | HSA=3, HBP=93 (byte-clk/lane-time units) |
| VIDEO_LINE_TIME | 0x2040002C | `0x5bf` | 1471 |
| VIDEO_VBLK_LINES | 0x20400030 | `0x0020641e` | **VSA=2, VBP=25, VFP=30** — matches stock timing |
| VIDEO_VACTIVE_LINES | 0x20400034 | `0x2d0` | **720** active lines |
| TIMEOUT_CNT_CLK_CONFIG | 0x20400040 | `0x72` | — |
| CMD_MODE_STATUS | 0x20400098 | `0x2a` | all cmd FIFOs empty — idle, nothing stuck |
| EOTP_EN | 0x204000BC | `0x0` | EOTP off |

## Reading

The DSI host is fully **armed and transmitting**: PLL locked, 2-lane RGB888
720×720 burst-video, both data lanes out of stopstate sending HS, vertical timing
(VSA=2 / VBP=25 / VFP=30) matching stock byte-for-byte, zero protocol errors, all
FIFOs idle. In this capture it is paired with a *visible* panel, so on the DSI
side the bring-up wall is **not present** in the handoff state.

Key contrast with the recorded failure mode: the stuck case shows `PHY_STATUS=0x1f32`
(bits 4,5 = data lanes parked in stopstate). Here those bits are clear — the lanes
are actually driving video. So when comparing the kernel-native path, watch for
those stopstate bits returning or for `VID_MODE_CFG`/timing diverging from the
table above.

Register/bit definitions: `src/linux-mainline-6-16-sprd/drivers/gpu/drm/sprd/sprd_dsi.c`.
