#!/usr/bin/bash

# Point DAC0 at the internal VBCIF path (not the external IIS port). This is the
# main fix: it is carried in the startup params, so it MUST be set before pcmtone
# opens a fresh stream. Without it the DSP drains MCDT to a null sink (free-run).
python3 tools/scripts/sercmd.py "/usr/local/bin/tmix 'VBC DAC0 Out VBCIF' 1"

# DSP-side VBC IIS master (likely NOT needed for the speaker/VBCIF path, kept for
# reference — IIS0 is the external I2S port). Set before a fresh stream.
#   1. select IIS0 as an INTERNAL master (DSP generates BCLK/LRCLK)
#   2. master word width: 0 = 16-bit (matches pcmtone's S16_LE)
#   3. start the master
python3 tools/scripts/sercmd.py "/usr/local/bin/tmix 'VBC IIS0 Master Internal' 1; /usr/local/bin/tmix 'VBC IIS Master Width 24bit' 0; /usr/local/bin/tmix 'VBC IIS Master Enable' 1"

# Set up routing
python3 tools/scripts/sercmd.py "/usr/local/bin/tmix 'TX0 SEL' 0; /usr/local/bin/tmix 'FE_FAST_PLAYBACK TX Switch' 1; /usr/local/bin/tmix 'Headphone Playback Switch' 1 1; /usr/local/bin/tmix 'Speaker Switch' 1"

# Test tone: 440 Hz, amp 12000, period 1280 frames (must be x160), 5 s.
python3 tools/scripts/sercmd.py "time /usr/local/bin/pcmtone 440 12000 1280 5"
