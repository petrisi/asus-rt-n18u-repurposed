# Stopping the call-home services

Good news first: **most of the bloat the GT-AC5300 fights does not exist on
this model.** The RT-N18U predates ASUS's Trend Micro / AiProtection stack
entirely.

Absent here, and worth not going looking for:

    ahs  asd  conn_diag  nt_center  nt_monitor  nt_actMail
    vis-dcon  vis-datacollector  netool  usbmuxd

Because `asd` does not exist, neither does its respawn watchdog, and the
`no_asd=1` discovery from the sibling project has nothing to apply to. This
model has its own respawner instead — see below.

## Survey before removing anything

    ps w
    nvram show 2>/dev/null | grep -iE "^(aae|webs_|cloud)" | sort

What this repository targets:

| process | what it is |
|---|---|
| `mastiff` | ASUS cloud / AAE call-home. **Respawns** — see below |
| `aaews` | AAE web service, same subsystem |
| `infosvr` | LAN discovery, UDP 9999, long CVE history |
| `lld2d` | Microsoft link-layer topology responder |
| `wpsaide` | WPS button helper |
| `u2ec` | USB-over-network printer sharing |
| `lpd` | line printer daemon |

**Leave `eapd` alone, and leave `nas` alone.** On this model *both* are part of
wireless authentication — `nas` is the Broadcom WPA authenticator, not a
file-sharing daemon as the name suggests. Killing either stops Wi-Fi clients
authenticating.

Leave `disk_monitor` too. It participates in USB hotplug handling, and on this
model USB *is* the boot hook.

`miniupnpd` is deliberately not in the kill list: it has a working GUI toggle
(WAN -> UPnP -> Disable), which is a better off switch than a kill loop.
`networkmap` and `avahi-daemon` are left running as local-only conveniences —
add them to `TARGETS` if you disagree.

## `mastiff` needs two things, not one

Killing `mastiff` achieves nothing on its own; it is back within about 60
seconds with new PIDs. `watchdog` is a symlink to `/sbin/rc`, so ASUS's own
init is the supervisor restarting it. Even the polite form does not stick:

    # service stop_mastiff
    Done.
    # sleep 60; pidof mastiff
    637 636 635 630

There is no `no_mastiff` flag. `mastiff` belongs to the **AAE** subsystem, and
the flag is named after that:

    nvram set aae_disable_force=1
    nvram set aae_enable=0
    nvram commit
    service stop_mastiff

**Both halves are required**, exactly as with `no_asd` on the GT-AC5300: the
flag alone does not stop a running instance, and the stop alone does not
prevent the restart. With the flag set, `mastiff` does not start at boot at
all, so the sweep never has to chase it.

### How that flag was found — the technique generalises

`rc`'s string table keeps a subsystem's control flags next to its start/stop
verbs. Grep with context:

    # strings /sbin/rc | grep -n -B8 -A8 start_mastiff
    aae_disable_force
    start_aae
    aaews
    ...
    start_mastiff
    mastiff &
    stop_mastiff

`aae_disable_force` is eight lines above `start_mastiff`. Use this on any
Asuswrt daemon that will not stay dead — it is faster than guessing nvram
names, and it works on the GT-AC5300 too.

## Sweep repeatedly, not once

Services come up staggered over the first minutes of boot, so a single kill
misses whatever starts later. `scripts/killsvc.sh` sweeps every 30 seconds, six
times, then logs the final state to `/jffs/killsvc.log`.

    cp killsvc.sh /jffs/killsvc.sh
    chmod 755 /jffs/killsvc.sh

It is invoked from the boot hook — see `02-persistence.md`.

## The firmware update check: nothing to disable

The sibling project stubs `/usr/sbin/webs_update.sh` because that firmware
polls ASUS roughly every 90 seconds. **This firmware appears not to poll at
all**, and stubbing would be impossible anyway on a squashfs rootfs.

Four independent checks, all negative:

| check | result |
|---|---|
| guard clause inside `webs_update.sh` | none — it reads no enable/disable nvram |
| `strings /sbin/rc \| grep webs_update` | no reference |
| `strings /usr/sbin/httpd \| grep -c webs_update` | `0` |
| `cru l` and `/var/spool/cron/crontabs/` | empty, after a full boot |

And the observable result — `webs_state_update`, `webs_state_flag`,
`webs_state_info`, `webs_last_info` and `webs_state_error` were all still empty
after roughly 25 minutes with a working WAN connection. `rc` only reads those
variables; it does not drive the check. It looks GUI-triggered.

If your unit behaves differently, those five nvram variables are a zero-cost
detector: baseline them, connect the WAN, and re-read. If they populate, the
fallback is an `/etc/hosts` blackhole written from the boot hook — `/etc` is
writable tmpfs — rather than a firewall rule.

## Confirming it worked

After a reboot:

    cat /jffs/killsvc.log
    for p in mastiff aaews infosvr lld2d u2ec lpd wpsaide; do
        printf "%s:%s " "$p" "$(pidof $p >/dev/null && echo UP || echo gone)"
    done; echo

Expect all `gone`. Then confirm you have not broken Wi-Fi:

    pidof eapd nas    # both must return a PID
