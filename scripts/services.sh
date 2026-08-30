#!/bin/sh
# Re-establish everything that lives on tmpfs and is therefore lost at boot:
# the /opt bind mount, the sshd privilege-separation account, and sshd itself.
# Invoked from /jffs/usbmount.sh (nvram script_usbmount).
#
# TO DISABLE: delete this file. The caller is [ -x ] guarded, so a missing
# file is a silent no-op and the router boots normally with telnet only.

USB_LABEL=ROUTERDATA
LOG=/jffs/services.log
LOCK=/tmp/services.lock

[ -f "$LOCK" ] && exit 0
touch "$LOCK"

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && rm -f "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

log "=== services start, uptime $(cut -d' ' -f1 /proc/uptime) ==="

# 1. Locate the volume by LABEL, never by device node: the stick moved from
#    /dev/sda1 to /dev/sdb1 across a single replug on this hardware.
MP=""
i=0
while [ "$i" -lt 30 ]; do
    dev=$(blkid 2>/dev/null | grep "LABEL=\"$USB_LABEL\"" | cut -d: -f1)
    if [ -n "$dev" ]; then
        MP=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)
        [ -n "$MP" ] && break
    fi
    sleep 2
    i=$((i + 1))
done

if [ -z "$MP" ]; then
    log "FATAL: volume LABEL=$USB_LABEL not mounted after 60s, giving up"
    exit 1
fi
log "volume $USB_LABEL mounted at $MP (device $dev)"

# 2. /opt is a symlink to tmp/opt, and /tmp is tmpfs -- recreate and re-bind.
if [ ! -d "$MP/entware" ]; then
    log "FATAL: $MP/entware missing -- is Entware installed?"
    exit 1
fi
mkdir -p /tmp/opt
if grep -q " /tmp/opt " /proc/mounts; then
    log "/tmp/opt already bound"
else
    mount -o bind "$MP/entware" /tmp/opt && log "bound $MP/entware -> /tmp/opt" \
        || { log "FATAL: bind mount failed"; exit 1; }
fi

# 3-5. OpenSSH needs its privilege-separation account, but the firmware
#      REGENERATES /etc/passwd during boot -- observed rewriting it one second
#      after this hook first added the account at 25s uptime. So adding it once
#      is not enough: add, verify, and retry until sshd actually starts.
#      /etc is a symlink into tmpfs, so this must happen on every boot.
#      UsePrivilegeSeparation was removed from OpenSSH; the account is not
#      optional.
#
#      LD_LIBRARY_PATH is cleared for the whole block: rc exports it pointing
#      at the firmware's libraries, which beats the DT_RUNPATH in every Entware
#      binary, so they load the wrong libc and die silently (rc.func discards
#      stderr). This is why /opt binaries work by hand but not from boot.
(
    unset LD_LIBRARY_PATH LD_PRELOAD

    # sshd binds ListenAddress 192.168.1.1 -- wait for br0 to hold it.
    i=0
    while [ "$i" -lt 30 ]; do
        ifconfig br0 2>/dev/null | grep -q "192.168.1.1" && break
        sleep 2
        i=$((i + 1))
    done

    if [ ! -x /opt/sbin/sshd ]; then
        log "FATAL: /opt/sbin/sshd not found"
        exit 1
    fi

    i=0
    while [ "$i" -lt 24 ]; do
        if pidof sshd >/dev/null 2>&1; then
            log "sshd running, pid $(pidof sshd)"
            break
        fi

        grep -q '^sshd:' /etc/passwd || \
            echo 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false' >> /etc/passwd
        grep -q '^sshd:' /etc/group || echo 'sshd:x:22:' >> /etc/group
        mkdir -p /var/empty && chmod 755 /var/empty

        # Verify rather than assume -- the firmware may have wiped it again.
        if grep -q '^sshd:' /etc/passwd && /opt/sbin/sshd -t 2>/dev/null; then
            /opt/sbin/sshd 2>>"$LOG"
            sleep 2
            if pidof sshd >/dev/null 2>&1; then
                log "sshd started on attempt $((i + 1)), pid $(pidof sshd)"
                break
            fi
        fi

        sleep 10
        i=$((i + 1))
    done

    pidof sshd >/dev/null 2>&1 || log "FATAL: sshd never started after $i attempts"
)

log "=== services done, uptime $(cut -d' ' -f1 /proc/uptime) ==="
exit 0
