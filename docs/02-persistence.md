# Making things survive a reboot

On the GT-AC5300 this was the hard part and the part that could brick the
router. Here it is neither. The RT-N18U has a real boot hook that ASUS ships
and that actually works.

## The hook that works: `script_usbmount`

The sibling project rules this variable out — on that firmware it is stored and
never read. **On the RT-N18U it works.** Do not carry that conclusion across
models; check per device.

Survey the firmware's own init binary before trusting anything:

    # for s in script_usbmount jffs2_scripts services-start post-mount init-start nat-start; do
    >   echo -n "$s "; grep -c "$s" /sbin/rc
    > done
    script_usbmount 1
    jffs2_scripts 0
    services-start 0
    post-mount 0
    init-start 0
    nat-start 0

Every Merlin-style hook is absent, as expected on stock. `script_usbmount` is
present, and it is not an orphaned nvram name — it sits inside the USB
mount-handling code:

    # strings /sbin/rc | grep -n -B2 -A2 script_usbmount
    APPS_DEV
    APPS_MOUNTED_PATH
    script_usbmount
    %s<%s
    cloudsync: enable=%d, ...

String presence is suggestive, not proof. Prove it:

    printf '#!/bin/sh\ndate >> /jffs/hook.log\necho "ARGS=[$*]" >> /jffs/hook.log\n' > /jffs/hook.sh
    chmod 755 /jffs/hook.sh
    nvram set script_usbmount=/jffs/hook.sh
    nvram commit

Then physically replug the stick and read `/jffs/hook.log`.

Two properties matter, both measured:

- **It fires at boot**, not only on hotplug — with the stick already inserted,
  at about 25 seconds of uptime on a cold boot. That is what makes it a
  persistence mechanism rather than a convenience.
- **It receives no arguments** (`ARGS=[]`). The script must locate the volume
  itself. Resolve it by label through `blkid`, never by device node: on this
  hardware the stick moved from `/dev/sda1` to `/dev/sdb1` across a single
  replug.

## What does not work, and why that is good news

The GT-AC5300 technique — replacing a real binary that `rc` executes, such as
`/usr/sbin/infosvr` — is impossible here.

    # mount -o remount,rw /
    # touch /usr/sbin/.wtest
    touch: /usr/sbin/.wtest: Read-only file system

The rootfs is squashfs: compressed and read-only by construction, not merely
mounted read-only. `/usr/sbin/infosvr` on this model *is* a real 18 KB ELF and
not a symlink to `rc`, so the sibling project's brick check passes — and it
still cannot be replaced.

Losing that technique removes the entire class of risk that dominates the other
repository. Nothing here writes outside `/jffs`, nvram and the USB stick. There
is no step where a typo replaces init.

## The chain

    nvram script_usbmount
        -> /jffs/usbmount.sh        backgrounds both stages, exits immediately
             -> /jffs/services.sh   /opt bind mount, sshd account, sshd
             -> /jffs/killsvc.sh    the telemetry sweep

`usbmount.sh` must return promptly — it runs inside `rc`'s mount handling, and
`killsvc.sh` deliberately sleeps for about three minutes. Backgrounding both is
not stylistic.

Every stage is `[ -x ]` guarded, so the disable path for any of it is `rm`:

    rm /jffs/killsvc.sh     # stop killing daemons, keep SSH
    rm /jffs/services.sh    # stop starting SSH, keep the sweep
    nvram set script_usbmount=""; nvram commit    # disable everything

Build every stage you add the same way. The recovery path should be `rm`, not
"boot into recovery mode".

## Stages start concurrently — wait, do not assert

The hook launches every stage at once, with no ordering. `transmission.sh`
needs `/opt`, which `services.sh` binds about 20 seconds later. A dependency
check *before* the loop therefore loses the race and the stage exits
permanently. Put such checks **inside** the loop.

The same applies to state the firmware destroys at runtime (`/etc/passwd`, bind
mounts): repair it every pass rather than setting it up once. Three separate
outages here had that single root cause.

Poll fast until converged, then back off — `services.sh` uses 10s until `/opt`
is bound and sshd is running, then 60s. On this model a flat 60s delayed SSH to
~130s of uptime; the adaptive version reaches it in ~55s. Fast polling is only
cheap because `blkid` produces no syslog noise here, which is **not** true of
every Asuswrt device.

## The failure mode is the USB stick

With no stick inserted, the hook never fires and none of this starts. The
router boots as stock ASUS firmware with telnet available if you left it on.

That is a real dependency and worth being deliberate about: the stick is not
optional storage here, it is the ignition key. It is also a clean failure —
pull it and the box reverts to stock behaviour with nothing half-applied.

## Does a firmware upgrade survive this?

Mostly, yes — another difference from the GT-AC5300, where a flash rewrites the
rootfs and destroys the hook.

Here the hook lives in nvram and the scripts live on `/jffs`, both of which
normally survive a firmware upgrade. What a flash *would* reset is anything the
upgrade chooses to clear in nvram, so re-check `script_usbmount` and
`aae_disable_force` afterwards.

A factory reset does destroy all of it. Keep the nvram table in
[CONFIG.md](../CONFIG.md).
