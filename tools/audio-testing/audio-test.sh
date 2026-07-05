#!/usr/bin/bash

# Hold agdsp access open for the whole session.
python3 tools/scripts/sercmd.py "echo 1 > /sys/kernel/debug/agdsp/access_hold"

# Route FAST_PLAYBACK > IIS0 (DAC0/TX0) > analog speaker path.
python3 tools/scripts/sercmd.py "tmix 'FE_NORMAL_AP01 TX Switch' 0; tmix 'TX0 SEL' 0; tmix 'FE_FAST_PLAYBACK TX Switch' 1"

# Max out the volumes.
python3 tools/scripts/sercmd.py "tmix 'Headphone Playback Switch' 1 1; tmix 'Speaker Switch' 1; tmix 'Headphone Volume' 15 15"

# Try to get a datapath open...
python3 tools/scripts/sercmd.py "tmix 'VBC DAC0 DP EN' 1; tmix 'VBC DAC0 Out VBCIF' 1; tmix 'VBC IIS Master Enable' 1; tmix 'VBC MUTEDG TX0 DSP' 0 1"

# Quick tone (foreground): 440 Hz, amp 12000, period 1280, 3 s, FAST dev, 2 ch.
python3 tools/scripts/sercmd.py "pcmtone 440 12000 1280 3 /dev/snd/pcmC0D0p 2"

# Diagnostic stuff
python3 tools/scripts/sercmd.py "pcmtone 440 12000 1280 10 /dev/snd/pcmC0D0p 2 &"
python3 tools/scripts/sercmd.py "sleep 3; echo -n 'EB0 mid : '; devmemn 0x335E0000; for o in 44 64 68 6c 30; do echo -n \"cgm+0x\$o: \"; devmemn 0x335D00\$o; done"
python3 tools/scripts/sercmd.py "echo '=== audif-status ==='; cat /sys/kernel/debug/sc2730-audif-status"
python3 tools/scripts/sercmd.py "echo '=== VBC_CTL scene-cmd ACKs (param[3]=DSP retval) ==='; grep -E 'ch=0 .*ACK' /sys/kernel/debug/agdsp/rxlog || cat /sys/kernel/debug/agdsp/rxlog"
