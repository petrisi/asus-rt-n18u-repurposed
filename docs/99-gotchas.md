# Platform traps

Read this before debugging anything. Every entry cost real time on this
hardware.

## Do not carry findings across models

The single most expensive assumption available. The sibling GT-AC5300 project
concludes that `script_usbmount` is a decoy. **On the RT-N18U it is the only
working boot hook.** Conversely, that project's binary-wrapping persistence is
impossible here.

Same vendor, same OS, opposite answers. Verify per device:

    strings /sbin/rc | grep -n -B8 -A8 <thing you are assuming>

## nvram accepts settings for features the firmware does not have

Writing `sshd_enable` and `sshd_authkeys` on stock RT-N18U appears to succeed
and does nothing — `httpd` discards nvram for features absent from
`rc_support`. Nothing errors. Check `nvram get` afterwards, and check
`rc_support`:

    nvram get rc_support | tr ' ' '\n' | grep -i <feature>

A GUI field or an accepted nvram write is not evidence that a feature exists.

## `/etc` is regenerated during boot

`/etc` is a symlink to `/tmp/etc` (tmpfs), and `rc` rewrites it while booting.
Anything a boot hook writes there early is destroyed without warning.

Observed: the hook fired at 25 s uptime and appended the `sshd` account to
`/etc/passwd` at 19:22:59; `sshd -t` failed one second later with *"Privilege
separation user sshd does not exist"*, and `/tmp/etc/passwd` had an mtime of
19:23 containing only `admin`, `nas`, `nobody`.

**Write to `/etc` with add-verify-retry, never add-once.** Add the entry,
re-`grep` to confirm it survived, attempt the dependent action, check the
observable result, sleep, repeat. `scripts/services.sh` retries every 10 s for
up to four minutes.

The general form of this mistake — logging success because a command did not
return an error — is worth watching for everywhere on this platform.

## The rootfs cannot be written, at all

    # mount -o remount,rw / ; touch /usr/sbin/.wtest
    touch: /usr/sbin/.wtest: Read-only file system

squashfs is compressed and read-only by construction. No remount helps. This
rules out replacing firmware binaries and stubbing shipped shell scripts.

## `StrictModes` rejects everything under `/opt`

    Authentication refused: bad ownership or modes for directory /tmp

OpenSSH walks the entire path to `authorized_keys`. `/opt` is a symlink to
`tmp/opt`, and `/tmp` is `0777`, so any key file under `/opt` fails no matter
how tight its own permissions are. Put it on `/jffs`. Do not set
`StrictModes no`.

## OpenSSH's privsep account is not optional

`UsePrivilegeSeparation no` was removed from OpenSSH. The `sshd` account must
exist in `/etc/passwd`, and this firmware does not ship one — combine with the
`/etc` regeneration trap above.

## Device nodes are not stable

The USB stick moved from `/dev/sda1` to `/dev/sdb1` across a single
unplug/replug, with no second disk present. Resolve volumes by label or UUID
and find the mountpoint in `/proc/mounts`.

## `tune2fs -L` silently reverts

Two separate mechanisms undo a relabel, both observed here:

1. **Relabelled while mounted** — the kernel holds the superblock in memory and
   flushes its cached copy, with the old label, on unmount. The new label can
   appear to work for a while and then revert at the next reboot.
2. **Relabelled with a dirty journal** — a later `e2fsck` replays the journal
   and restores the old superblock.

Order: `umount`, `e2fsck -p`, `tune2fs -L`, `sync`, then verify with a *second*
`e2fsck` followed by `blkid`.

## `LD_LIBRARY_PATH` kills Entware binaries launched from `rc`

`rc` exports it pointing at firmware libraries; it beats the `DT_RUNPATH` in
Entware binaries, which then load the wrong libc and die. `rc.func` discards
stderr, so the symptom is a service that simply never starts — and that works
perfectly when you run it by hand, because interactive sessions do not inherit
the variable.

    ( unset LD_LIBRARY_PATH LD_PRELOAD ; /opt/bin/whatever )

## Shell arithmetic overflows silently at 2^31

busybox `ash` truncates with no error. Interface byte counters pass 2^31 within
days of uptime, so anything doing shell arithmetic on them starts producing
zeroes that look like idle links. Do the maths in `awk`, which uses doubles.

## Missing utilities

This is a thinner busybox than the GT-AC5300's. Absent, among others:

    id      od

Check before relying on anything outside the obvious core.

## `$HOME` is tmpfs

`/root` is a symlink to `/tmp/home/root`. Anything writing config to `$HOME`
loses it on reboot.

## There is no RTC — the clock is wrong until NTP

With no WAN connection the router boots believing it is 2018. This matters for
anything time-series: rrdtool rejects updates older than the last one, so a
multi-year jump when NTP finally syncs will corrupt a database. Confirm `date`
is sane before starting any collector.

## ASUS `httpd` owns port 80

On the LAN address and on loopback. Bind anything of your own elsewhere.

## Do not plug the WAN port into the router's own LAN

Obvious in hindsight, silent in practice. The WAN DHCP client will take a lease
from the router's *own* DHCP server and set the router as its own gateway:

    wan0_ipaddr  = 192.168.1.20
    wan0_gateway = 192.168.1.1
    ping 1.1.1.1 -> Network is unreachable

Both sides then sit on `192.168.1.0/24` and nothing routes. `link_internet=1`
still reads as success, so trust `ping`, not the flag.

## The web API session expires quickly

Scripted `appGet.cgi` work stops returning JSON and starts returning a redirect
to `Main_Login.asp` after a short idle period. Re-authenticate rather than
concluding that the endpoint broke.
