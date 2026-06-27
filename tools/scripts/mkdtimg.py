#!/usr/bin/env python3
import struct, sys

DT_TABLE_MAGIC = 0xd7b7ab1e
HEADER_SIZE = 32
ENTRY_SIZE = 32
PAGE_SIZE = 2048

def main(dtb_path, out_path):
    fdt = open(dtb_path, 'rb').read()
    entries_off = HEADER_SIZE
    dt_off = HEADER_SIZE + ENTRY_SIZE
    total = dt_off + len(fdt)

    hdr = struct.pack('>8I', DT_TABLE_MAGIC, total, HEADER_SIZE, ENTRY_SIZE,
                      1, entries_off, PAGE_SIZE, 0)
    entry = struct.pack('>8I', len(fdt), dt_off, 0, 0, 0, 0, 0, 0)

    with open(out_path, 'wb') as f:
        f.write(hdr); f.write(entry); f.write(fdt)
    print('wrote %s (%d bytes, fdt %d)' % (out_path, total, len(fdt)))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
