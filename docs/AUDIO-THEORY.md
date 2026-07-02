# Audio Bring-Up Theory

Mainline Linux 6.16 on the Anbernic RG Rotate (Unisoc UMS512 / T618, sharkl5pro).
Goal: a real tone out of the single on-board speaker. Status: **still hiss, no
tone** — but the failure is now localized to one interface (read on).

> **If you are new to this file, read "Current State" + "The Wall" + "Open
> hypotheses". Everything below "History" is a condensed audit trail of dead ends,
> kept for provenance.**

---

## Current State (2026-06-28, session 5)

The break has been narrowed from "somewhere in a long DSP/codec chain" down to a
**single interface: `aud_top` digital codec → AUDIF → sc2730 analog DAC.**

What that means concretely:

- The **analog output chain is healthy and correctly routed.** The hiss we hear is
  the sc2730 DAC's *own* analog noise floor traveling the full intended path
  (sc2730 DAC → HP mixer → Speaker mux → aw87391 PA → speaker). Proven by a control
  walk: the hiss needs **both** `Headphone Playback Switch=1 1` **and**
  `Speaker Switch=1`; turning *either* off silences it. So if real samples reach
  the sc2730 DAC, they *will* come out the speaker.
- **No digital audio reaches the sc2730 DAC.** Two independent proofs:
  1. **Amplitude test:** `pcmtone` at amp 0 (silence) vs amp 30000 (full) sound
     *absolutely identical*. Our PCM never modulates the output.
  2. **SDM-DC poke:** slamming the `aud_top` DAC sigma-delta DC offset
     (`devmemn 0x33750038` alternating `0x0000`/`0xffff` at ~6 Hz, during a held
     stream so the codec stays resumed) produced **no audible change** — only the
     PA startup pop. So even the `aud_top`'s *own* digital output does not reach
     the speaker.

Combine the two: the sc2730 DAC plays its analog noise to the speaker fine, but it
**never receives the digital stream from `aud_top` over AUDIF.** That link is the
wall.

### The signal path, annotated

```
 AP DDR buffer
   │  agcp_dma "fast_p" (ch9)            [WORKS: DMA flows, CHN0_SRC advances]
   ▼
 MCDT DAC FIFO ch4 (0x33490010)          [WORKS: r1p0, DRQ asserts, DSP drains]
   │  AGDSP firmware drains FIFO         [WORKS: IPC acks; but free-runs ~37-44x]
   ▼
 VBC (AGCP domain)                       [opaque from AP; muxes set, no audible effect]
   │  VBCIF (internal) ── or ── IIS0 (external I2S)
   ▼
 aud_top digital codec @0x33750000       [programmed: DAC on, SDM seeded]
   │  AUDIF  ◄────────────────────────── ***THE WALL: nothing crosses here***
   ▼
 sc2730 analog DAC (PMIC)                [WORKS downstream: noise floor → speaker]
   │  HP mixer → Speaker mux
   ▼
 aw87391 PA (i2c-2 @0x58, GPIO9) → speaker   [WORKS: bound, enables, carries noise]
```

The two free-run facts (DSP drains MCDT at 37–44× real time, no back-pressure) and
the dead AUDIF link are very likely the **same root cause**: nothing downstream is
consuming at 48 kHz, so (a) there is no back-pressure to pace the DSP, and (b) the
sc2730 DAC gets no clocked digital feed. A missing/!running **48 kHz DA clock in
the AGCP/AON audio domain** would explain both at once.

---

## The Wall: `aud_top → AUDIF → sc2730`

Everything upstream of AUDIF has been exercised without producing a tone, and
everything downstream is proven to work. The remaining suspects, all at or around
the AUDIF interface:

1. **sc2730 DAC input not selected to AUDIF**, or the PMIC-side AUDIF *receiver* is
   not enabled. Mainline [sc2730.c](../src/linux-7-1-sprd/sound/soc/codecs/sc2730.c)
   wires the AUDIF clock supplies (`CLK_AUDIF`, `CLK_AUDIF_6M5`, `CLK_AUD_SCLK`,
   `CLK_TOPA_6M5`) as DAPM supplies and writes `AUD_AUDIF_CTL0 = 0` at probe, but we
   have **not verified on silicon** that the AUDIF receiver path is actually live
   during a stream (the sc2730 PMIC audio regs are not in regmap-debugfs — they are
   behind the ADI/PMIC bus).
2. **`aud_top` not transmitting on AUDIF** because it has no 48 kHz DA clock. The
   AGCP DA sample clock is generated inside the (AP-opaque) AGDSP domain; if it
   never runs, `aud_top` produces nothing to send and the DSP free-runs. This is the
   same missing clock hypothesized above.
3. **AUDIF format/mode mismatch** beyond `AUDIF_CTL0 = 0` (bit widths, 5P mode,
   master/slave). The vendor clears `BIT_AUDIF_5P_MODE` (covered by `=0`) *and*
   pulses a soft-reset (now added, see below) but there may be more.

### What we already tried at/near the wall (no breakthrough)

- **AUDIF soft-reset** (vendor does it on every codec power-up; mainline never did):
  added a `POST_PMU` pulse of `AUD_CFGA_SOFT_RST` (reg `0x0104`, bits
  `DAC_POST_SOFT_RST|DIG_6P5M_SOFT_RST = 0x6`) on the `CLK_TOPA_6M5` supply in
  [sc2730.c](../src/linux-7-1-sprd/sound/soc/codecs/sc2730.c). Built, flashed —
  amplitude test still identical.
- **`aud_top` digital codec** is correctly programmed during a stream (verified via
  regmap-debugfs, no devmem): `AUD_TOP_CTL(0x00)=0x5` (DAC L+R on),
  `AUD_DAC_CTL(0x0c)=0x1`, SDM seeded (`0x38=0x9999`, `0x3c=0x1`). Its register block
  is complete at `0x3c`; it is a passive modulator with **no clock-master regs**.

---

## Proven working (do not re-litigate)

- **AP→MCDT transport.** `agcp_dma "fast_p"` (ch9) pushes DDR→MCDT DAC ch4 FIFO
  (`0x33490010`); `CHN0_SRC` advances through the ring. MCDT is **r1p0**
  (`ums512-mcdt → sprd_mcdt_r1_info`; `FIFO_CLR=0x14c`). An r2 experiment was a
  regression and was reverted.
- **AP↔AGDSP IPC.** Mailbox inbox+outbox (IRQ 82/83) round-trips; every VBC command
  (`STARTUP/KCTL_SET/HW_PARAMS/HW_TRIGGER/SHUTDOWN`) is delivered and **acked**
  (`sprd_agdsp_send_cmd` returns 0). The `supp-outbox` ENXIO at boot is cosmetic
  (optional 3rd IRQ, unused on ums512).
- **Startup-param struct layout.** Mainline
  [vbc-v4-dsp.c](../src/linux-7-1-sprd/sound/soc/sprd/vbc-v4-dsp.c)
  `vbc_startup_params` matches the vendor's `{stream_info + snd_pcm_startup_paras}`
  *positionally* field-for-field (`name32/fe_id/stream` → `stream_info`;
  `tx_id/rx_id/ref_rx_id` → `dac/adc/ref_adc id`; `rx_source/tx_out` →
  `adc_source/dac_out`; … `iis_master`, `mst_sel` aligned). Routing params land at
  the right offsets.
- **Digital codec pm_runtime** (`ums9230-digital.c`): pinned resumed across writes;
  `AUD_TOP_CTL`/`AUD_DAC_CTL` reach silicon during a stream.
- **Speaker PA** aw87391 (i2c-2 @0x58, GPIO9): driver bound, enables, carries the
  noise floor to the speaker.
- **Analog output route** (see Current State): healthy end-to-end.

## Proven NOT the gate (this session)

- **VBC IIS master** (`IIS_MASTER_START` / `EXT_INNER_IIS_MST_SEL` /
  `IIS_MASTER_WIDTH`): added as kcontrols, set live and via startup params
  (`vbc_startup_reload=1`). No effect on pacing or audio. **IIS0 is the external
  I2S port, not in the speaker path.**
- **`mux_dac_out` (DAC source = VBCIF vs IIS):** added kcontrol `VBC DAC0 Out VBCIF`.
  Genuinely reroutes (drain rate jumps 44×→327×) but produces **no audible signal**
  — consistent with the wall being further downstream (AUDIF).
- **Playback gains / output routing:** `Headphone Volume` (was 0 at boot, max 15),
  swap-DAC-channels, earpiece-vs-headphone — none change the amp-0-vs-loud result.

## Driver changes made this session (all in tree, boot_a only unless noted)

- [vbc-v4-dsp.c](../src/linux-7-1-sprd/sound/soc/sprd/vbc-v4-dsp.c): kcontrols
  `VBC IIS Master Enable` / `VBC IIS Master Width 24bit` / `VBC IIS0 Master Internal`
  / `VBC DAC0 Out VBCIF`; these write both the live KCTL and the startup params.
  *(Infra — kept, but proven not the tone gate.)*
- [sc2730.c](../src/linux-7-1-sprd/sound/soc/codecs/sc2730.c): AUDIF soft-reset
  (`sc2730_audif_reset_event`, `POST_PMU` on `CLK_TOPA_6M5`).
- [sprd-pcm-dma.c](../src/linux-7-1-sprd/sound/soc/sprd/sprd-pcm-dma.c): dropped the
  cosmetic "invalid dma pointer" warning (single-channel cyclic `tx_status` quirk;
  returns position 0 quietly).

---

## Open hypotheses / next steps (for fresh eyes)

Ordered by promise:

1. **Verify the sc2730 PMIC-side AUDIF receiver + DAC input on silicon.** We have
   never confirmed the analog DAC is actually told to take its input from AUDIF, nor
   that the AUDIF RX is enabled, *during a stream*. The sc2730 audio regs live behind
   the ADI/PMIC bus and are not in regmap-debugfs — need a debug read path (extend a
   tool, or a temporary `regmap_read` dump in
   [sc2730.c](../src/linux-7-1-sprd/sound/soc/codecs/sc2730.c)) to inspect
   `AUD_AUDIF_CTL0`, the DAC enable/mux, and `AUD_CFGA_*` status during playback, and
   diff against the vendor's expected values.
2. **Chase the AGCP/AON 48 kHz DA clock.** Both symptoms (DSP free-run + dead AUDIF)
   unify if the DA sample clock never runs. The AGCP-internal clock is opaque from
   the AP. Compare the vendor's clock/scene setup for a *normal speaker DA* stream
   against what mainline sends; check whether a clock/scene enable is missing.
3. **AUDIF format/mode.** Re-check `AUDIF_CTL0` against the vendor for bit width and
   master/slave; confirm the soft-reset timing (we pulse it on `CLK_TOPA_6M5`
   POST_PMU — it may need to fire after *all* AUDIF clocks, or after the DAC enable).
4. **Loopback sanity.** The `aud_top` has `AUD_LOOP_CTL (0x1c)`; an ADC→DAC internal
   loopback (mic to speaker) would prove the `aud_top`→AUDIF→sc2730→speaker chain
   independent of VBC, isolating whether the break is AUDIF transport vs upstream
   data.

## Tooling / how to reproduce

- **Binaries on eMMC** at `/usr/local/bin/` (persist across reboot): `pcmtone`,
  `tmix`, `i2cprobe`, `devmemn`. Source in
  [tools/audio-testing/](../tools/audio-testing/).
- **`pcmtone freq amp period secs`** — opens `pcmC0D0p`, S16_LE 48 kHz stereo,
  holds for `secs` wall-seconds. The pacing metric is "wrote N s of audio" / wall:
  ~1× = real-time clocked, ~37–44× = free-running into a null sink.
- **`tmix`** — `tmix` lists; `tmix "Name"` **reads** value+range; `tmix "Name" v…`
  writes. (Read mode added this session — beware older builds where name-only *wrote*
  0.)
- **`devmemn ADDR [VAL]`** — MMIO peek/poke. **Only touch the codec block
  `0x3375xxxx` while a stream is actively holding it resumed**, else async SError →
  panic → unclean reboot (which zeroes freshly-written eMMC files — re-`sync` and
  re-`md5sum` after every transfer).
- **Serial:** `/dev/ttyACM0` via
  [tools/scripts/sercmd.py](../tools/scripts/sercmd.py) (run commands) and
  [tools/scripts/sertx.py](../tools/scripts/sertx.py) (file transfer).
- **Routing recipe:** `tmix 'TX0 SEL' 0; tmix 'FE_FAST_PLAYBACK TX Switch' 1;
  tmix 'Headphone Playback Switch' 1 1; tmix 'Speaker Switch' 1` (+ `Headphone
  Volume 15 15`). See [tools/audio-testing/just-test.sh](../tools/audio-testing/just-test.sh).
- **regmap-debugfs:** `/sys/kernel/debug/regmap/33750000.audio-codec/registers`
  (aud_top dig codec) and `/sys/kernel/debug/regmap/2-0058/` (aw87391). Safe to read
  any time. The **sc2730 PMIC audio codec is NOT here** (ADI bus) — that gap is
  itself a problem for diagnosing the wall.
- **DAPM:** `/sys/kernel/debug/asoc/rg-rotate/<component>/`. Sample DAPM *during* a
  held stream — it powers down on close.

---

## History (condensed — superseded framings, kept for provenance)

The investigation passed through several framings, each disproven:

- **Session 1 — "transport stuck":** AP DMA source looked frozen at buffer base
  `0x87400000`. Root cause was the test client tearing down at trigger (EPIPE on 2nd
  write) plus a single-channel `tx_status`/pointer-math quirk (`dma_addr_offset==0`
  zero-width window). Fixed `pcmtone` SW_PARAMS (full-buffer start threshold,
  `stop_threshold=LONG_MAX`); transport then ran cleanly. The "stuck at base" was a
  reporting artifact, not a real stall.
- **Session 2 — "wrong MCDT revision":** an `r2_info` build misaddressed `FIFO_CLR`
  so the DAC FIFO never asserted DRQ. Reverting to **r1p0** made the AP DMA flow.
  Reached the **HISS milestone** (analog stage alive). Also: dig-codec pm_runtime
  cache_only race fixed; aw87391 PA driver written and bound.
- **Session 3–4 — "IIS0 not clocked / SDM / interface gates":** added SDM seed
  (vendor-correct, necessary-not-sufficient), enabled the IIS0/VBCIF/SRC48K/VBC-24M
  interface clock gates (were off), reviewed the sprd-dma guards (none block
  transport). Established the DSP free-runs ~37× draining MCDT to a null sink.
- **Session 5 — this file:** ruled out the entire VBC mux/master surface as audibly
  inert; proved (amplitude + SDM-poke tests) that **no digital audio reaches the
  sc2730 DAC**, and that the analog output chain is healthy. **Localized the wall to
  the `aud_top → AUDIF → sc2730` digital link.**

### Reference material

- Vendor audio driver (the authoritative register/sequence source):
  `vendor/linux-kernel-5-4-ums512/kernel_modules/.../audio_driver/sprd/` — VBC DAI in
  `dai/vbc/v4/vbc_dai/`, sc2730 codec in `codec/sprd/sc2730/` (AUDIF reset lives in
  `include/aud_topa_rf.h: sprd_codec_audif_clk_enable`).
- Persisted agent notes: see the project memory `audio-bringup.md` for the blow-by-blow.
```
