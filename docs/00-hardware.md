# The hardware

| | |
|---|---|
| SoC | Broadcom BCM470x "Northstar", ARMv7 |
| RAM | 256 MB (`MemTotal: 255892 kB`) |
| Flash | 128 MB NAND — squashfs read-only rootfs plus a writable JFFS2 partition |
| Radio | single-band 2.4 GHz, **Broadcom BCM4360** |
| Wired | 4× gigabit LAN, 1× gigabit WAN |
| USB | one USB 3.0, one USB 2.0 (three USB buses present) |
| Bootloader | CFE `2.0.0.7` |
| Firmware | `3.0.0.4.382_52308` is the last one, **kernel 2.6.36** |
| Userland | BusyBox v1.17.4 |

    # uname -a
    Linux RT-N18U 2.6.36.4brcmarm #1 PREEMPT Fri Mar 28 10:07:02 CST 2025 armv7l GNU/Linux

Note the kernel: 2.6.36, a 2010 kernel, still being shipped in a 2025 build.
Nothing modern runs directly on it. Everything useful comes from Entware, which
is why `04-usb-and-entware.md` matters more here than on newer hardware.

## The decision this forces on you

**The radio is a BCM4360, and OpenWrt has no driver for it.**

    # wl -i eth1 revinfo
    vendorid 0x14e4
    deviceid 0x43a1
    chipnum 0x4360

OpenWrt's `bcm53xx` target falls back to the reverse-engineered `b43` driver,
which does not support the 4360 at all. Flashing OpenWrt turns this into a
wired-only box — permanently, since the driver situation is a licensing
problem, not a missing-work problem.

The other escape route is also closed: Asuswrt-Merlin has an unofficial RT-N18U
fork, but it ships **no binary releases** — source only. Using it means
building Asuswrt from source first.

So the practical options are:

| path | SSH | Wi-Fi | packages |
|---|---|---|---|
| **stock + this repository** | yes, via Entware | yes | yes, via Entware |
| OpenWrt | yes | **no** | yes |
| Merlin fork | yes | yes | yes, but you must build it yourself |

This repository takes the first. If you do not need the radio, OpenWrt's modern
userland is a real argument — decide before you invest in the setup below.

## Storage layout

    /              squashfs, READ-ONLY      29.1 MB, 100% full — the firmware
    /jffs          jffs2, writable          62.8 MB, ~61 MB free
    /tmp           tmpfs                    volatile, cleared on reboot
    /tmp/mnt/<label>                        USB volumes
    /opt -> tmp/opt                         dangling until you bind-mount it

    # cat /proc/mtd
    mtd0: 00080000 00020000 "boot"        512 KB   CFE
    mtd1: 00180000 00020000 "nvram"       1.5 MB
    mtd2: 03e00000 00020000 "linux"       62 MB
    mtd3: 03c71e94 00020000 "rootfs"      60.4 MB
    mtd4: 03ec0000 00020000 "brcmnand"    62.75 MB  mounted as /jffs
    mtd5: 00140000 00020000 "asus"        1.25 MB

`/jffs` is the only writable persistent storage without a USB stick, and it is
NAND that will never be reflashed. Avoid writing to it on a timer.

**The rootfs being squashfs is the single most important fact about this
platform.** It is compressed and read-only by construction, not merely mounted
read-only:

    # mount -o remount,rw / ; touch /usr/sbin/.wtest
    touch: /usr/sbin/.wtest: Read-only file system

That closes off every technique that involves replacing a firmware binary, and
it is why `02-persistence.md` looks nothing like its GT-AC5300 counterpart.

## 32-bit, consistently

Unlike the GT-AC5300 there is no kernel/userland split to trip over — kernel
and userland are both 32-bit ARM. The Entware target is `armv7sf-k2.6`,
matching the 2.6 kernel.

The busybox `ash` arithmetic limit still applies in full: shell arithmetic
silently truncates past 2^31, and interface byte counters pass that within days
of uptime. Do the maths in `awk`. See `99-gotchas.md`.
