# Repurposing the ASUS RT-N18U

Getting a root shell on an RT-N18U, replacing telnet with real SSH, stopping
the vendor call-home daemons, and turning it into something useful.

This router is end of life. The final firmware (`3.0.0.4.382_52308`) shipped in
March 2025 and there will be no more. It is a single-band 2.4 GHz router from
2014, obsolete as a router, and still a perfectly good little ARM box with
256 MB of RAM, 128 MB of NAND and two USB ports.

Everything here was worked out on stock firmware. **No custom firmware, no
bootloader unlock, no soldering, no opening the case.**

This is a sibling to [asus-gt-ac5300-repurposed](https://github.com/petrisi/asus-gt-ac5300-repurposed).
Much of the shape is the same, but **the two models differ in ways that matter
more than they look**, and several of that repository's central techniques do
not work here at all. Those differences are called out where they arise; the
short version is in [99-gotchas.md](docs/99-gotchas.md).

## What you get

- A root shell that survives reboots
- OpenSSH with key-only login, replacing the firmware's telnet
  ([01-getting-shell.md](docs/01-getting-shell.md))
- The ASUS call-home daemons stopped permanently — including the one that
  respawns ([03-disable-telemetry.md](docs/03-disable-telemetry.md))
- Entware, so you have a real package manager
  ([04-usb-and-entware.md](docs/04-usb-and-entware.md))
- A dependency-free status dashboard, using the firmware's own lighttpd
  ([05-dashboard.md](docs/05-dashboard.md))
- Optional long-term history via rrdtool — a year in 1.1 MB that never grows
  ([07-rrd-history.md](docs/07-rrd-history.md))

## Start here

| | |
|---|---|
| [00-hardware.md](docs/00-hardware.md) | what the box is, and the one decision it forces on you |
| [01-getting-shell.md](docs/01-getting-shell.md) | stock has no SSH at all — getting in, then fixing that |
| [02-persistence.md](docs/02-persistence.md) | **making anything survive a reboot** |
| [03-disable-telemetry.md](docs/03-disable-telemetry.md) | **stopping the call-home services for good** |
| [04-usb-and-entware.md](docs/04-usb-and-entware.md) | storage and a package manager |
| [05-dashboard.md](docs/05-dashboard.md) | the status portal |
| [07-rrd-history.md](docs/07-rrd-history.md) | long-term history (optional) |
| [99-gotchas.md](docs/99-gotchas.md) | **the platform traps — read this before debugging anything** |

Set your values in [CONFIG.md](CONFIG.md) first. Deferred work is tracked in
[TODO.md](TODO.md).

## Read this before you start

**You are unlikely to brick this router.** That is not bravado, it is a
property of the hardware: the root filesystem is squashfs, so it is physically
read-only and nothing here modifies it. Everything lives on `/jffs`, in nvram,
or on a USB stick. The disable path for any stage is `rm`.

This is the opposite of the GT-AC5300, where the only available boot hook was
overwriting a binary in a writable read-only-mounted rootfs, one typo away from
replacing init. That technique is impossible here — and losing it is what
removes the risk.

The one thing you can still lose is your configuration, by factory-resetting to
recover from a mistake. Keep a note of your nvram changes; they are listed in
each document.

This is your own hardware. Disabling telemetry on a device you own is
unremarkable; if you are doing it to someone else's, that is between you and
them.

## Scope

One model, one firmware build: RT-N18U on `3.0.0.4.382_52308`. Every command
here was run on that combination and the output checked. Where something was
inferred rather than observed, it says so.

MIT licensed. No warranty, in the legal sense and the practical one.
