#!/usr/bin/env python3
"""Run shell commands on the device over /dev/ttyACM0 (autologin root shell)."""
import sys, serial, time, re

PORT, BAUD = "/dev/ttyACM0", 115200
PROMPT = b"root@rgrotate:~#"
ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")

def clean(b):
    return ANSI.sub(b"", b).replace(b"\r", b"").decode(errors="replace")

def run(ser, cmd, timeout=30):
    ser.reset_input_buffer()
    ser.write(cmd.encode() + b"\n")
    ser.flush()
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            # prompt reappears after command finishes (skip the immediate echo line)
            if buf.count(PROMPT) >= 1 and buf.rstrip().endswith(PROMPT):
                break
        else:
            time.sleep(0.05)
    text = clean(buf)
    lines = text.split("\n")
    # drop echoed command (first line) and trailing prompt line
    if lines and cmd in lines[0]:
        lines = lines[1:]
    lines = [l for l in lines if "root@rgrotate" not in l]
    return "\n".join(lines).strip()

def main():
    ser = serial.Serial(PORT, BAUD, timeout=0.4)
    ser.write(b"\n"); time.sleep(0.4); ser.reset_input_buffer()
    for cmd in sys.argv[1:]:
        print(f"### $ {cmd}")
        print(run(ser, cmd))
        print()
    ser.close()

if __name__ == "__main__":
    main()
