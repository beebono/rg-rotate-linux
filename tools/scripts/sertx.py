#!/usr/bin/env python3
"""Transfer a local file to the device over ttyACM0 via gzip+base64 chunks.
Usage: sertx.py <localfile> <remotepath>
"""
import sys, serial, time, re, gzip, base64, os

PORT, BAUD = "/dev/ttyACM0", 115200
PROMPT = b"root@rgrotate:~#"
ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")

def wait_prompt(ser, timeout=20):
    buf = b""; deadline = time.time()+timeout
    while time.time() < deadline:
        c = ser.read(4096)
        if c:
            buf += c
            if buf.rstrip().endswith(PROMPT): return buf
        else: time.sleep(0.03)
    return buf

def send(ser, line):
    ser.reset_input_buffer()
    ser.write(line.encode()+b"\n"); ser.flush()
    return wait_prompt(ser)

def main():
    local, remote = sys.argv[1], sys.argv[2]
    data = open(local,"rb").read()
    gz = gzip.compress(data, 9)
    b64 = base64.b64encode(gz).decode()
    md5 = __import__("hashlib").md5(data).hexdigest()
    print(f"{local}: {len(data)} bytes -> gz {len(gz)} -> b64 {len(b64)} (md5 {md5})")

    ser = serial.Serial(PORT, BAUD, timeout=0.4)
    ser.write(b"\n"); time.sleep(0.3); ser.reset_input_buffer()
    send(ser, f"rm -f {remote}.b64 {remote}.gz {remote}")
    CH = 256
    nchunks = (len(b64)+CH-1)//CH
    for i in range(0, len(b64), CH):
        send(ser, f"printf '%s' '{b64[i:i+CH]}' >> {remote}.b64")
        print(f"\r  chunk {i//CH+1}/{nchunks}", end="", flush=True)
    print()
    send(ser, f"base64 -d {remote}.b64 | gunzip > {remote} && chmod +x {remote}")
    out = send(ser, f"md5sum {remote}; ls -l {remote}")
    print(ANSI.sub(b"", out).replace(b"\r",b"").decode(errors="replace"))
    print(f"EXPECT md5: {md5}")
    ser.close()

if __name__ == "__main__":
    main()
