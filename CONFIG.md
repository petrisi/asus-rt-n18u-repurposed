# Values you must set

Every script in this repository is written against these. Change them once,
here, and grep for them before you run anything.

| value | default | where |
|---|---|---|
| Volume label | `BTDATA` | `USB_LABEL`/`DATA_LABEL` in `scripts/services.sh`, `USB_LABEL` in `rrd_feeder.sh` and `rrd_export.sh`, `DATA_LABEL` in `scripts/transmission.sh` |
| Transmission RPC creds | `/jffs/portal/.trrpc` (mode 600) | read by `portal_collector.sh` |
| BitTorrent peer port | `51413` | `PEER_PORT` in `scripts/transmission.sh` |
| SSH listen address | `192.168.1.1` | `ListenAddress` in `/opt/etc/ssh/sshd_config` |
| Authorized keys path | `/jffs/.ssh/authorized_keys` | `AuthorizedKeysFile` in `sshd_config` |
| Service log | `/jffs/services.log` | `LOG` in `scripts/services.sh` |
| Kill-sweep log | `/jffs/killsvc.log` | `LOG` in `scripts/killsvc.sh` |
| Run-once locks | `/tmp/services.lock`, `/tmp/killsvc.lock` | `LOCK`, both scripts |

One label now, not two: this deployment consolidated onto a single disk (see
`docs/09-single-disk-migration.md`), so every script resolves the same volume.
If you run two volumes, `USB_LABEL` (the one carrying `/opt` and the RRDs) and
`DATA_LABEL` (bulk storage) can differ.

## Why the USB volume is found by label, not device node

`/dev/sda1` is not stable. On this hardware the stick moved from `/dev/sda1` to
`/dev/sdb1` across a **single** unplug/replug, with no second disk involved.
`services.sh` resolves the volume through `blkid` by label, then finds its
mountpoint in `/proc/mounts`.

If you would rather not depend on the label at all, the UUID is stabler still —
see the relabelling trap in [99-gotchas.md](docs/99-gotchas.md), which is a
good argument for not trusting labels too much either.

## Why authorized_keys lives on /jffs and not on the USB stick

OpenSSH's `StrictModes` walks the whole path to `authorized_keys` and refuses
anything group- or world-writable. `/opt` is a symlink to `tmp/opt`, and `/tmp`
is mode `0777`, so a key file under `/opt` fails with:

    Authentication refused: bad ownership or modes for directory /tmp

`/jffs` is `0755` under `/` at `0755`, so it passes. Do not "fix" this by
setting `StrictModes no`.

## Interface names on this model

    eth0    WAN
    br0     LAN bridge (all four wired ports plus the radio)
    eth1    2.4 GHz radio -- the only radio; this is a single-band router
    vlan1   wired switch side of the bridge

    nvram get wl_ifnames   -> eth1
    nvram get lan_ifnames  -> vlan1 eth1

These differ between models. Check before assuming.

## nvram changes this repository makes

Keep this list. A factory reset loses all of it.

| variable | value | why |
|---|---|---|
| `script_usbmount` | `/jffs/usbmount.sh` | the boot hook — see `docs/02-persistence.md` |
| `aae_disable_force` | `1` | stops `mastiff` respawning — see `docs/03-disable-telemetry.md` |
| `aae_enable` | `0` | disables the ASUS cloud subsystem |
| `telnetd_enable` | `0` | after SSH is confirmed working — see `docs/01-getting-shell.md` |
