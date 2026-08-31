# Migrating Entware from ROUTERDATA to BTDATA

**Executed 2026-08-31.** Kept as the record of what was done, and as the
rollback procedure. The trigger was the stick failing to enumerate after a
physical move, then throwing `EXT3-fs error ... remounting filesystem
read-only` on a later boot — two independent signals.

Outcome: Entware and the RRDs now live on `BTDATA`; a cold boot brings the
whole stack up from that one disk (`/opt` bound from `/dev/sda1`, sshd at 105s
uptime, transmission following, dashboard and history serving). The old stick
was unmounted, `e2fsck`'d clean and relabelled `ROUTERDATA-OLD`. Its `e2fsck`
came back clean, so the corruption was contact-related rather than media
failure — worth knowing before condemning a stick.

## Why

`script_usbmount` is the only boot hook on this model, so the stick carrying
Entware also carries the trigger for SSH, the telemetry sweep, the dashboard
and the RRDs. On 2026-08-31 that stick stopped enumerating after the router was
physically moved — the kernel never saw it, so nothing could mount it, and SSH
and Transmission were unavailable until it was reseated. It came back fine, so
the stick is not dead; the contact is marginal.

Consolidating onto the 128 GB `BTDATA` volume removes a whole failure domain:
**one USB device instead of two**, a physically larger connector that seats
more firmly, and a healthier device. The only thing lost is the ability to pull
the data disk without stopping the stack — which is not something worth
preserving.

## What makes this easy

`/opt` is a **bind mount**, not a copy. Entware's absolute `/opt/...` paths keep
working regardless of which volume backs it, so migration is: move the tree,
change the bind source, and change the label the scripts look for. **No package
reinstallation, no rebuild.**

What lives where, before migration:

| Path | Volume | Moves? |
|---|---|---|
| `<ROUTERDATA>/entware` → `/opt` | ROUTERDATA | **yes** |
| `<ROUTERDATA>/rrd/*.rrd` | ROUTERDATA | **yes** |
| `/opt/etc/ssh/ssh_host_*` | inside entware | yes, with the tree |
| `/opt/etc/transmission/settings.json` | inside entware | yes, with the tree |
| `/jffs/.ssh/authorized_keys` | internal NAND | no |
| `/jffs/*.sh`, `nvram script_usbmount` | internal NAND / nvram | no |
| `<BTDATA>/torrents/*` | BTDATA | already there |

`settings.json` already points `download-dir` at `/tmp/mnt/BTDATA/...`, so it
needs no edit.

## Backup already taken

    /tmp/mnt/BTDATA/backup/routerdata-YYYYMMDD-HHMM.tar.gz   (~12 MB gzipped)
    /tmp/mnt/BTDATA/backup/routerdata-YYYYMMDD-HHMM.manifest (665 entries)
    /tmp/mnt/BTDATA/backup/routerdata-YYYYMMDD-HHMM.md5
    /tmp/mnt/BTDATA/backup/routerdata-latest.tar.gz          (symlink)

Taken with the writers quiesced. Verify before relying on it:

    cd /tmp/mnt/BTDATA/backup && md5sum -c routerdata-*.md5

## Procedure

Do this over SSH with the GUI reachable as a fallback, and read
[99-gotchas.md](99-gotchas.md) first.

### 1. Stop the stages

    killall transmission.sh portal_start.sh services.sh
    sleep 70          # they may be inside a sleep; traps fire when it ends
    killall -9 transmission.sh portal_start.sh services.sh 2>/dev/null
    killall -9 transmission-daemon lighttpd portal_collector.sh 2>/dev/null
    rm -rf /tmp/services.lock.d /tmp/transmission.lock.d /tmp/portal/.portal.lock.d

**Leave `sshd` running** — it is your way in. Its binary is under `/opt`, which
stays mounted until the next step.

### 2. Copy the tree

Either from the live volume:

    cp -a /tmp/mnt/ROUTERDATA/entware /tmp/mnt/BTDATA/entware
    cp -a /tmp/mnt/ROUTERDATA/rrd     /tmp/mnt/BTDATA/rrd

...or from the backup, if the stick is unavailable:

    mkdir -p /tmp/restore && cd /tmp/restore
    tar -xzf /tmp/mnt/BTDATA/backup/routerdata-latest.tar.gz
    cp -a ./entware /tmp/mnt/BTDATA/entware
    cp -a ./rrd     /tmp/mnt/BTDATA/rrd

`cp -a` matters: Entware contains symlinks (`/opt/sbin/mkfs.ext4 -> mke2fs`)
and mode bits that a plain `cp -r` would flatten.

Verify the copy before trusting it:

    ls -l /tmp/mnt/BTDATA/entware/sbin/mkfs.ext4     # must still be a symlink
    ls /tmp/mnt/BTDATA/entware/bin/opkg              # must exist
    ls /tmp/mnt/BTDATA/entware/etc/ssh/ssh_host_ed25519_key

### 3. Re-point the bind mount

    umount /tmp/opt 2>/dev/null || umount -l /tmp/opt
    mount -o bind /tmp/mnt/BTDATA/entware /tmp/opt
    ls /opt/sbin/sshd        # must exist, now served from BTDATA

Existing SSH sessions survive this; new ones need sshd restarted, which the
stage does.

### 4. Change the label the scripts look for

    sed -i 's/^USB_LABEL=ROUTERDATA/USB_LABEL=BTDATA/' /jffs/services.sh
    sed -i 's/^USB_LABEL=ROUTERDATA/USB_LABEL=BTDATA/' /jffs/portal/rrd_feeder.sh
    sed -i 's/^USB_LABEL=ROUTERDATA/USB_LABEL=BTDATA/' /jffs/portal/rrd_export.sh

`services.sh` then has `USB_LABEL=BTDATA` and `DATA_LABEL=BTDATA` pointing at
the same volume. That is fine and idempotent: `ensure_data_mount` mounts it,
`ensure_opt` binds `entware/` from it, and the duplicate-mount cleanup compares
device *and* mountpoint so it will not unmount the volume it just mounted.

Confirm no `ROUTERDATA` references remain:

    grep -rn ROUTERDATA /jffs/*.sh /jffs/portal/*.sh

### 5. Restart and verify

    nohup /jffs/services.sh >/dev/null 2>&1 &
    sleep 15
    nohup /jffs/transmission.sh >/dev/null 2>&1 &
    nohup /jffs/portal/portal_start.sh >/dev/null 2>&1 &

Then reboot and check from a cold start — that is the only test that counts:

    grep -c /tmp/opt /proc/mounts          # 1
    pidof sshd lighttpd transmission-daemon
    for s in services.sh transmission.sh portal_start.sh; do
        echo "$s: $(pidof $s | wc -w)"     # 1 each
    done
    rrdtool lastupdate /tmp/mnt/BTDATA/rrd/sys.rrd   # current timestamp
    curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.1:8080/

### 6. Retire the old stick

Only once a cold boot has fully succeeded **without** it:

    umount /tmp/mnt/ROUTERDATA

Then physically remove it — and keep it untouched as a rollback image. Do not
reformat it until you have run for a week on `BTDATA`.

## Rollback

The old stick is unmodified by this procedure, so rollback is:

    sed -i 's/^USB_LABEL=BTDATA/USB_LABEL=ROUTERDATA/' /jffs/services.sh \
        /jffs/portal/rrd_feeder.sh /jffs/portal/rrd_export.sh

...reinsert the stick and reboot.

## What this does not fix

The boot hook still depends on **a** USB volume mounting. If `BTDATA` fails to
enumerate, the stack does not start — the dashboard included, since even though
it needs no USB at runtime, `script_usbmount` is what launches it. That is a
property of the platform (see [02-persistence.md](02-persistence.md)) and
consolidating disks does not change it. It does halve the number of connectors
that can work loose.
