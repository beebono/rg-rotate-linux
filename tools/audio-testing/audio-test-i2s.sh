#!/usr/bin/bash
#
# DSP-free AP-I2S speaker path test. See docs/AUDIO-I2S-PATH-ATTEMPT.md.
#
# Premise: the `sprd-i2s` CPU DAI masters the internal IIS0 bus into aud_top from
# the AP, so PCM flows  AP DMA -> sprd-i2s -> aud_top "I2S RX" -> AUDIF -> sc2730
# -> HP -> analog amp -> speaker  with the audio DSP ASLEEP. This converts the
# intractable "wake the DSP" problem into "master a standard I2S controller".
#
# WHY THIS IS A NEAR-EMPTY SCRIPT (vs audio-test.sh): the AP-I2S path deliberately
# touches NONE of the DSP/VBC machinery. Everything the old script poked is gone:
#   - agdsp access_hold          (no DSP access needed)
#   - FE_*/TX0 SEL/FAST_PLAYBACK (no DPCM frontend; I2S_SPK is a static PCM)
#   - VBC DAC0 DP EN / Out VBCIF / IIS Master Enable / MUTEDG  (VBC is bypassed)
#   - VBC Custom/System Device   (DSP is never told anything)
#   - VBC Profile ... Mode       (no DSP topology handshake)
#   - AUD_CP_CLK_CORE CGM pokes  (DSP-fenced muxes are irrelevant; our master
#                                 clock is CLK_AP_IIS0 <- twpll_153m6 via clk fw)
# The digital chain (I2S RX -> AUDIF_TX -> Digital DAC switches) is powered
# automatically by DAPM when the I2S_SPK PCM opens, so no digital tmix is needed.
#
# The ONLY mixer controls touched are the sc2730 ANALOG output stage, which is
# shared by every route to this board's speaker (DAC -> HP -> anbernic,rgds-amp).
# If it turns out DAPM already powers these, this list can shrink further.
#
# GO/NO-GO is a single register field, no ears required:
#   sc2730-audif-trace addr_w ADVANCES  => internal AP->aud_top route is REAL,
#                                          DSP-free speaker audio. Proceed.
#   addr_w stays 0                      => aud_top never got AP PCM; route needs
#                                          the (absent) pad loopback. Kill it,
#                                          fall back to USB-C.

set -u
SER="python3 tools/scripts/sercmd.py"

# I2S_SPK PCM. Appended last in the card, so it is the highest pcmC0D*p index;
# confirm with `aplay -l` / `ls /dev/snd`. Override: DEV=pcmC0D<n>p ./audio-test-i2s.sh
DEV="${DEV:-/dev/snd/pcmC0D10p}"
TONE="pcmtone 440 12000 1280 5 ${DEV} 2"          # 48k-ish 440Hz, 5s, backgrounded

# The one observable that decides everything. addr_w = sc2730 DAC FIFO write ptr.
TRACE="cat /sys/kernel/debug/sc2730-audif-trace 2>/dev/null | grep -E 'addr_w|addr_r|empty'"
STATUS="grep -E 'DAC_FIFO|AUDIF_STS|RAW_STS' /sys/kernel/debug/sc2730-audif-status"

# AUD_CP_CLK_CORE base (DSP-local 0x015D0000 + 0x32000000). CGM_AUD=0x68 (aud_top
# core), CGM_AUDIF=0x6c (AUDIF serializer master -> sc2730). Both read 0 (parked
# 26M/SEL=0) = wall (b). Anchor CGM_DSP_CORE@0x20 must read sane (~0x3).
A=0x335D00

# AP IIS0 controller MMIO base (sharkl5pro: i2s@70c00000). Only accessible while
# the PCM is open (the driver gates CLK_IIS0_EB in .startup), so read mid-tone.
I2S=0x70c000

# ---------------------------------------------------------------------------
# Analog output: unmute sc2730 DAC -> Headphone, and enable the Speaker pin so
# DAPM powers the amp (HP -> Speaker Amp IN -> Speaker). These are the ONLY
# controls we set. If any errors as "not found", it's harmless - drop it.
# ---------------------------------------------------------------------------
$SER "tmix 'Headphone Playback Switch' 1 1; tmix 'Headphone Volume' 15 15; tmix 'Speaker Switch' 1"

# Sanity: card enumerated the I2S_SPK PCM and the DAI probed cleanly?
$SER "echo '=== PCM devices (expect an I2S_SPK playback dev) ==='; aplay -l 2>/dev/null | grep -iE 'I2S_SPK|card 0'; \
echo '=== sprd-i2s probe (no error expected) ==='; dmesg | grep -iE 'sprd-i2s|i2s@70c00000' | tail -5"

# ---------------------------------------------------------------------------
# THE EXPERIMENT: open + play the I2S_SPK PCM (this powers the whole digital
# chain via DAPM and starts the AP IIS0 master), then watch addr_w.
# ---------------------------------------------------------------------------
$SER "pkill pcmtone 2>/dev/null; sleep 0.3; ${TONE} &"
$SER "sleep 2; echo '=== AP IIS0 controller alive? (CTRL0 b14=DMA-en, CLKD=bitclk div) ==='; \
echo -n '  CTRL0(0x08): '; devmemn ${I2S}08; \
echo -n '  CLKD (0x04): '; devmemn ${I2S}04; \
echo -n '  STS2 (0x2c): '; devmemn ${I2S}2c"
# $SER "echo '=== GO/NO-GO: sc2730 DAC FIFO write pointer ==='; ${TRACE}; sleep 1; ${TRACE}"
$SER "echo '=== audif status ==='; ${STATUS}"

# DISAMBIGUATE a addr_w=0 result: is aud_top itself powered+waiting (=> route
# absent), or did our card DAPM never turn its DAC side on (=> our wiring bug)?
# AUD_TOP_CTL@0x33750000: b0=DACL b2=DACR (0x5 => both DAC switches ON).
# AUD_DAC_CTL@0x3375000c: b15=mute, low nibble=fs. Also peek the DSP-owned AUD/
# AUDIF CGM muxes (still parked at 26M is expected; not our lever here).
$SER "echo '=== aud_top powered+waiting? (DACL/DACR switches during I2S play) ==='; \
echo -n '  AUD_TOP_CTL(0x00) [b0=DACL b2=DACR, 0x5=both on]: '; devmemn 0x33750000; \
echo -n '  AUD_DAC_CTL(0x0c) [b15=mute low-nib=fs]:          '; devmemn 0x3375000c; \
echo -n '  CGM_AUD  (0x335D0068):                            '; devmemn 0x335D0068; \
echo -n '  CGM_AUDIF(0x335D006c):                            '; devmemn 0x335D006c"
$SER "echo '=== any i2s/dma errors during play? ==='; dmesg | grep -iE 'i2s|iis0|dma|xrun|underrun' | tail -8"
$SER "pkill pcmtone 2>/dev/null; echo '=== PART A done ==='"

# ---------------------------------------------------------------------------
# PART B - isolate the TWO walls that a addr_w=0 conflates:
#   (a) IIS0 -> aud_top connectivity absent, vs
#   (b) aud_top -> AUDIF -> sc2730 DAC-write path blocked (CGM_AUD/AUDIF parked).
#
# Method: keep the I2S_SPK tone playing (so playback DAPM holds AUD_TOP_CTL DAC
# switches ON = 0x5 and AUDIF stays live), THEN force aud_top's internal ADC->DAC
# digital loopback. That writes the sc2730 DAC FIFO from aud_top's own ADC, with
# IIS0/VBC/DSP entirely out of the path. (Loopback alone is inconclusive - it only
# enables the ADC switches, not the DAC ones - which is why the earlier doc attempt
# saw AUDIF_STS=0x00. Running it concurrent with playback supplies the DAC side.)
#
#   addr_w ADVANCES with loopback -> DAC-write path (b) is GOOD => the PART A
#       addr_w=0 is purely IIS0->aud_top connectivity (a). KILL confirmed cleanly:
#       AP masters IIS0 perfectly but nothing internally carries it to aud_top.
#   addr_w STILL 0 with loopback -> the DAC-write path (b) itself is blocked (AUDIF/
#       AUD clock parked at 26M). Then PART A's addr_w=0 does NOT prove anything
#       about connectivity - the AP master might be reaching aud_top invisibly - and
#       the real remaining blocker is clocking AUDIF, not the IIS route.
# ---------------------------------------------------------------------------
$SER "pkill pcmtone 2>/dev/null; sleep 0.3; ${TONE} &"
$SER "sleep 1; echo '=== PART B: aud_top ADC->DAC digital loopback DURING I2S play ==='; \
tmix 'AUD_TOP Digital Loopback' 1; sleep 1; \
echo -n '  AUD_TOP_CTL(0x00) [expect DAC b0/b2 + ADC b1/b3 on]: '; devmemn 0x33750000; \
echo '  --- addr_w (does the DAC FIFO now fill from the loopback?) ---'; \
${TRACE}; sleep 1; ${TRACE}; ${STATUS}; \
tmix 'AUD_TOP Digital Loopback' 0"
$SER "pkill pcmtone 2>/dev/null; echo '=== PART B done ==='"

# ---------------------------------------------------------------------------
# PART C - THE settling test: crack wall (b) against the live AP-I2S feed.
#
# addr_w has NEVER advanced on this device (DSP path, I2S path) and the loopback
# kills AUDIF, so "feed sc2730's DAC FIFO" (wall b) is unconquered independent of
# who masters IIS0 - it masks the connectivity question (wall a). What is NEW here
# vs every prior CGM poke: a REAL 48k master (sprd-i2s) is actually driving IIS0
# into aud_top, so if we now give aud_top a live AUDIF/AUD datapath clock, the
# chain could complete - and addr_w advancing would prove BOTH (b) cracked and (a)
# connectivity real, in one shot.
#
# CGM_AUD(0x68)/CGM_AUDIF(0x6c) are parked at SEL=0 (26M). Prior finding: 0x6c
# SEL 0/1 keep AUDIF alive, SEL 2/3 select an absent source (AUDIF dies). Even a
# WRONG-rate-but-live clock should make aud_top serialize DAC data => addr_w moves
# (wrong pitch is fine; we only need it nonzero). Methodology: the datapath latches
# its clock at TRIGGER, so set the CGM while the stream is DOWN, then start a fresh
# tone. Poke-then-trigger per value.
#
# WARNING: raw /dev/mem writes to DSP-domain clock muxes. A bad value can wedge
# audio; if it hangs, reboot. All writes are live (no reflash).
# ---------------------------------------------------------------------------
$SER "pkill pcmtone 2>/dev/null; echo -n '  ANCHOR CGM_DSP_CORE(0x20) [sane ~0x3]: '; devmemn ${A}20"

# First: can the AP even WRITE these CGMs? (0x50/0x4c reject; 0x6c was found
# writable+effective; 0x68 unknown.) Set both to SEL=1, read back.
$SER "pkill pcmtone 2>/dev/null; sleep 0.2; \
devmemn ${A}68 0x00000001 >/dev/null; devmemn ${A}6c 0x00000001 >/dev/null; \
echo -n '  writable? CGM_AUD(0x68) rb=';  devmemn ${A}68; \
echo -n '           CGM_AUDIF(0x6c) rb='; devmemn ${A}6c; \
devmemn ${A}68 0x00000000 >/dev/null; devmemn ${A}6c 0x00000000 >/dev/null"

# Sweep: for each SEL, set 0x68+0x6c while DOWN, then trigger a fresh tone and
# read addr_w. SEL 0/1 expected live; 2/3 likely kill AUDIF (kept for the record).
$SER "for s in 0 1 2 3; do \
  echo; echo \"########## CGM_AUD/AUDIF SEL=\$s (set while DOWN, then trigger) ##########\"; \
  pkill pcmtone 2>/dev/null; sleep 0.3; \
  devmemn ${A}68 0x0000000\$s >/dev/null; devmemn ${A}6c 0x0000000\$s >/dev/null; \
  echo -n '  0x68 rb='; devmemn ${A}68; echo -n '  0x6c rb='; devmemn ${A}6c; \
  ${TONE} & \
  sleep 2; ${TRACE}; ${STATUS}; \
done; pkill pcmtone 2>/dev/null"

# Park both back at 0 so we leave the box in the known baseline state.
$SER "devmemn ${A}68 0x00000000 >/dev/null; devmemn ${A}6c 0x00000000 >/dev/null; \
echo '=== PART C done (CGMs re-parked) ==='"

# INTERPRETATION (PART C):
#   addr_w nonzero at ANY SEL -> BREAKTHROUGH: aud_top delivered our AP-I2S PCM to
#       sc2730. Connectivity (a) is real AND wall (b) is crackable from the AP. Pin
#       the working SEL, then chase the correct 48k-locked rate (twpll_153m6 parent)
#       and format. This is the win.
#   0x68/0x6c readback stays 0 (writes rejected) -> the AUDIF/AUD clock is AP-fenced
#       like the VBC CGMs. Wall (b) is DSP-owned and unreachable -> internal path
#       dead for a KNOWN reason (not a guess). Pivot to USB-C.
#   writes stick but addr_w stays 0 at every live SEL -> aud_top is not forwarding
#       DAC data even with a running AUDIF clock => either (a) really is unwired, or
#       aud_top needs a DSP-only enable we can't reach. Path dead; USB-C.

$SER "echo '=== ALL DONE ==='"

# INTERPRETATION (PART A):
#   addr_w advanced  -> SUCCESS. The AP internally drives aud_top. Wire the full
#                       card/amp path and tune format (24-bit AUDIF) next.
#   addr_w == 0, but CTRL0 b14 set & CLKD sane -> the AP IIS0 master IS running;
#                       PART B then says whether that 0 means "route absent" (b GOOD)
#                       or "DAC path blocked, verdict masked" (b also 0).
#   CTRL0/CLKD read 0 or abort -> the controller didn't come up (clock/base/DMA);
#                       fix that before drawing any conclusion about the route.
