# RG Rotate initramfs

A minimal busybox initramfs whose `/init` pets the watchdogs, forces the USB
gadget into peripheral role, then `switch_root`s into the Debian rootfs on
`mmcblk3p74` (falling back to a recovery shell on the gadget serial). See
[overlay/init](overlay/init).

This directory holds **only authored inputs**; the populated initramfs tree and
the `cpio.gz` are generated into `build/initramfs/` (gitignored).

## Layout

| Path | Tracked | What |
|------|---------|------|
| `overlay/` | yes | files copied verbatim over the busybox tree (currently just `init`) |
| `busybox.config` | yes | the `.config` that builds the busybox binary |
| `build-initramfs.sh` | yes | builds busybox from the `src/busybox` submodule and assembles the ramdisk |

## Reproduce

```bash
git submodule update --init src/busybox
src/initramfs/build-initramfs.sh
# -> build/initramfs/initramfs.cpio.gz
```

Then feed `build/initramfs/initramfs.cpio.gz` to `mkbootimg` (see the root
README / CLAUDE.md boot.img recipe).

Environment overrides: `CROSS_COMPILE` (default `aarch64-linux-gnu-`), `JOBS`,
`BUSYBOX_DIR`, `CONFIG`, `OUT_DIR`.
