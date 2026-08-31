# Transmission

This box makes a usable low-power seedbox: one core, 256 MB of RAM, and it is
already powered on anyway. Seeding is read-dominated, and reads are the thing
this hardware is actually good at.

Distribute things you have the right to distribute. Linux images are the
obvious case and the one this was built for.

## Why this needs a second disk, unlike the sibling project

On the GT-AC5300 the USB stick is storage. **Here it is the ignition key.**
`script_usbmount` is the only boot hook this model has, so the boot stick
carries the trigger for SSH, the telemetry sweep, the dashboard, the RRD
databases and the sshd host keys. Pointing sustained BitTorrent writes at it
means flash wear and I/O contention on the one device the whole stack depends
on, and a filesystem corruption there costs you remote access, not just
downloads.

So: **a separate disk, always.** These notes assume a second volume labelled
`BTDATA`, mounted at `/tmp/mnt/BTDATA`. `scripts/services.sh` mounts it — the
firmware's automounter does **not** pick it up, verified across a reboot.

## Measured on this hardware

| | |
|---|---|
| sequential read | 28.4 MB/s (228 Mbps) |
| random read, 48 distinct 4 MB chunks, cold cache | 38.4 MB/s (307 Mbps) |
| sequential write | 21.3 MB/s (171 Mbps) |
| SHA1 hashing (transmission-create, 64 MB) | ~32 MB/s |
| CPU idle at rest | 86% |

Storage is not the bottleneck for seeding; a domestic upload link will run out
long before this does.

## Install

    unset LD_LIBRARY_PATH LD_PRELOAD
    opkg install transmission-daemon transmission-web transmission-remote

Entware carries 4.0.3 for this target, plus an older 2.77 build. 4.0.3 costs
about 10 MB of RAM here, which is affordable.

## Lock down the RPC before starting it

In `/opt/etc/transmission/settings.json`:

    "rpc-enabled": true,
    "rpc-bind-address": "127.0.0.1",
    "rpc-whitelist": "127.0.0.1",
    "rpc-whitelist-enabled": true,
    "rpc-authentication-required": true,
    "rpc-username": "admin",
    "rpc-password": "<yours>",
    "peer-port": 51413,
    "port-forwarding-enabled": false,
    "download-dir": "/tmp/mnt/BTDATA/torrents/complete",
    "incomplete-dir": "/tmp/mnt/BTDATA/torrents/incomplete"

Bound to loopback, whitelisted, and password protected. The daemon rewrites the
password as a salted hash on first run, which is expected. `chmod 600` the file.

Verify all three properties rather than assuming them:

    # from another host on the LAN -- must be refused
    curl http://<router>:9091/                      -> connection refused
    # locally, wrong password
    transmission-remote 127.0.0.1:9091 -n admin:wrong -si   -> 401: Unauthorized
    # locally, correct password
    transmission-remote 127.0.0.1:9091 -n admin:<pw>  -si   -> daemon version

`rpc-host-whitelist-enabled` is set to `false` because the connection arrives
through an SSH tunnel as `127.0.0.1`; leaving host whitelisting on is a common
cause of an otherwise-correct tunnel returning errors.

## Reaching the web UI

Do not open 9091 to the network. Tunnel it:

    ssh -i ~/.ssh/rtn18u -L 9091:127.0.0.1:9091 admin@192.168.1.1

Then browse to `http://127.0.0.1:9091/`. The RPC never leaves the box and
access is gated by your SSH key.

## Peer port

The peer port does need to be reachable, on both address families:

    iptables  -I INPUT 1 -i eth0 -p tcp --dport 51413 -j ACCEPT
    iptables  -I INPUT 1 -i eth0 -p udp --dport 51413 -j ACCEPT
    ip6tables -I INPUT 1 -i eth0 -p tcp --dport 51413 -j ACCEPT
    ip6tables -I INPUT 1 -i eth0 -p udp --dport 51413 -j ACCEPT

UDP matters — µTP and DHT both use it. `ip6tables` is a **separate table**: a
v4-only rule set means a dual-stack seed quietly serves no v6 peers at all.
`scripts/transmission.sh` maintains all four, deleting before inserting so
repeated passes cannot stack duplicates.

Note that if this router sits behind another one, the upstream device also
needs the port forwarded, or you will seed only to peers you connect out to.

## Starting it reliably

`scripts/transmission.sh` launches the daemon directly rather than through
`/opt/etc/init.d/S88transmission`, because `rc.func` discards stderr and a
failure to start is otherwise completely invisible — and on this platform it
*will* fail, thanks to the `LD_LIBRARY_PATH` problem in
[04-usb-and-entware.md](04-usb-and-entware.md).

Three rules it enforces:

**Never let `download-dir` resolve into tmpfs.** If the volume is missing and
the path falls back into `/tmp`, Transmission downloads into RAM, appears to
work, and eventually takes the router down. The mount is re-checked before
*every* start. Verified by unmounting the disk and confirming the refusal:

    REFUSING to start: /tmp/mnt/BTDATA is not mounted (download-dir would fall into tmpfs)

...and confirming it recovers on its own once the disk returns — 20 s in
testing, with `services.sh` remounting and the stage then starting the daemon.

**A slow start is not a failed start.** On slow USB storage the daemon can take
20 s or more to appear. Waiting three seconds, declaring failure and letting
the next pass launch a second instance gives you two daemons fighting over the
config lock, both dying, every interval, indefinitely. The stage waits up to
40 s.

**One instance only.** `script_usbmount` fires on every USB mount event, so the
stage takes an atomic `mkdir` lock; without it, inserting a disk starts a rival
copy. See [99-gotchas.md](99-gotchas.md).

## Tuning for 256 MB and one core

    "cache-size-mb": 4,
    "peer-limit-global": 120,
    "peer-limit-per-torrent": 30,
    "lpd-enabled": false

Defaults are 200 global and 50 per torrent, which is a lot of sockets and
conntrack entries for this box. Raise them only if you measure headroom.

## Surfacing it on the dashboard

`portal_collector.sh` samples Transmission on its 30s slow path and emits a
`bt` block in `status.json`: running state, torrent counts by state, current
rates, peer count, progress, and lifetime byte totals. The history layer adds
`bt.rrd` (download, upload, peers) and two charts.

Three decisions worth keeping:

**The RPC stays authenticated.** Transmission rewrites `rpc-password` in
`settings.json` as a salted hash on first run, so a script cannot read the
plaintext back — which makes "just disable RPC auth" the tempting fix. Store
the plaintext in a root-only file instead (`/jffs/portal/.trrpc`, mode 600,
same pattern as `.htdigest`). The dashboard is exposed to the WAN on an
unpatched lighttpd; an unauthenticated localhost RPC would be a much better
prize behind any future request-forgery-shaped flaw.

**Bound the RPC call.** A wedged `transmission-daemon` must not freeze the
collector, so the call runs under the same backgrounded-poll ceiling as the
`wl` ioctls (`run_to`, 5s then SIGKILL). Verified afterwards that
`status.json` still advances on its 2s cadence.

**Lifetime totals come from `stats.json`, not the RPC.** That file carries
exact byte counters (`uploaded-bytes`, `downloaded-bytes`), so there is no
human-formatted "12.29 MB" to parse back into a number.

**Rates are GAUGE, not DERIVE.** Transmission reports kB/s — already a rate.
DERIVE would differentiate it a second time and render nonsense.

One parsing note: torrent state is matched by keyword, not column position,
because names contain spaces and ETA is sometimes one token ("Unknown") and
sometimes two ("42 min"). `Up & Down` counts as **downloading** — it means both
at once on an incomplete torrent, and classifying it as seeding reported a
67%-complete torrent as "seeding".

## Accounting

Lifetime totals live in `/opt/etc/transmission/stats.json`, readable without
the RPC password. It is rewritten every few minutes, so it is exact for totals
and lumpy for rates.
