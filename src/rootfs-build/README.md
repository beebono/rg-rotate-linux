# RG Rotate Debian rootfs

Builds the on-eMMC Debian 13 (trixie) arm64 rootfs that the initramfs
`switch_root`s into on `mmcblk3p74`.

This directory holds **only authored scripts**; the base tarball and the ext4
image are large generated artifacts and are gitignored.

## Two steps

```bash
# 1. base rootfs tarball (unprivileged, via mmdebstrap)
./make-rootfs-tar.sh          # -> debian-trixie-arm64.tar

# 2. configured ext4 userdata image (fakeroot; preserves ownership/setuid)
./make-image.sh               # -> debian-userdata.img  (4 GiB, flash to mmcblk3p74)
```

`make-image.sh` layers the device config onto the base tar: autologin root on
the `ttyGS0` gadget console, `fstab`/hostname, passwordless root, the USB
peripheral-role unit, and the `hw-watchdog` service (feeds AP `wd0` + sc2730
`wd1`). Edit that script to change device configuration.

## Generated (gitignored)

| File | ~Size | What |
|------|-------|------|
| `debian-trixie-arm64.tar` | 305M | mmdebstrap base (step 1 output / step 2 input) |
| `debian-userdata.img` | 4G | final ext4 image flashed to the rootfs partition |
| `debian-userdata.img.tar` | 305M | tarred image for transfer |

Overrides: `make-rootfs-tar.sh` takes `SUITE`/`ARCH`/`MIRROR`/`PACKAGES`;
`make-image.sh` takes `IMG_MB`.
