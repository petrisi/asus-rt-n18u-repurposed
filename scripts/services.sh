#!/bin/sh
# Establishes and then MAINTAINS everything that lives on tmpfs and is lost or
# destroyed at runtime: the /opt bind mount, the sshd privilege-separation
# account, and sshd itself.
#
# Invoked from /jffs/usbmount.sh (nvram script_usbmount).
#
# TO DISABLE: delete this file. The caller is [ -x ] guarded, so a missing
# file is a silent no-op and the router boots normally with the GUI available.
#
# ==================== WHY THIS MAINTAINS RATHER THAN ASSERTS ================
#
# An earlier version did its setup once per boot, guarded by a stamp file.
# That is wrong, and it locked us out of SSH. Plugging in a second USB device
# does BOTH of these, mid-boot, with no reboot involved:
#
#   1. The firmware regenerates /etc/passwd (to set up share users), which
#      deletes the sshd privsep account. sshd's listener stays up, so the port
#      still answers, but every new connection dies before the banner:
#      "kex_exchange_identification: read: Connection reset by peer".
#
#   2. Device nodes renumber (the boot stick moved sda -> sdc), so the volume
#      is unmounted and remounted -- which silently destroys the /tmp/opt bind
#      mount, taking /opt/sbin/sshd with it.
#
# Both are recoverable only if something re-checks them. Hence the loop below.
# The single-instance lock is a CONCURRENCY guard, not a run-once guard: the
# hook fires on every USB mount event and must not stack up loops.

USB_LABEL=ROUTERDATA
# Optional second volume for bulk data (BitTorrent payloads). The firmware's
# automounter does NOT pick this up -- verified across a reboot: blkid sees
# LABEL="BTDATA" but nothing mounts it -- so we mount it ourselves. Absent
# disk is a silent no-op.
DATA_LABEL=BTDATA
LOG=/jffs/services.log
LOCKDIR=/tmp/services.lock.d
# Poll fast until everything is up, then back off. The dependencies this stage
# waits for (the volume mount, /opt) appear at unpredictable times during boot,
# and at a flat 60s a single missed pass delayed SSH to ~130s uptime. Fast
# polling is cheap here specifically because blkid produces NO syslog noise on
# this model -- verified, 0 matches in 3286 lines. Do not copy that assumption
# to other hardware; on the GT-AC5300 blkid floods the log with ubi errors.
INTERVAL_FAST=10
INTERVAL=60

# The hook fires on every USB mount event. One maintenance loop is enough.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && rm -f "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Entware binaries load the wrong libc and die silently if rc's
# LD_LIBRARY_PATH is inherited; rc.func discards stderr, so there is no
# message at all. This is why /opt works by hand and not from boot.
unset LD_LIBRARY_PATH LD_PRELOAD

# Resolve the volume by LABEL, never by device node: it moved from sda1 to
# sdb1 across one replug, and to sdc1 when a second disk was attached.
find_mp() {
    _dev=$(blkid 2>/dev/null | grep "LABEL=\"$USB_LABEL\"" | cut -d: -f1)
    [ -n "$_dev" ] || return 1
    awk -v d="$_dev" '$1==d {print $2; exit}' /proc/mounts
}

# Mount a labelled volume at /tmp/mnt/<LABEL> if it exists and is not already
# mounted. Resolved by label: device nodes shuffle constantly on this box --
# the boot stick has been sda1, sdb1 and sdc1 across three reboots.
ensure_data_mount() {
    _mp="/tmp/mnt/$DATA_LABEL"
    _d=$(blkid 2>/dev/null | grep "LABEL=\"$DATA_LABEL\"" | cut -d: -f1)
    [ -n "$_d" ] || return 1

    if ! grep -q " $_mp " /proc/mounts 2>/dev/null; then
        mkdir -p "$_mp"
        if mount -t ext4 -o rw,noatime "$_d" "$_mp" 2>/dev/null; then
            log "mounted $_d ($DATA_LABEL) at $_mp"
        else
            log "WARN: $_d ($DATA_LABEL) present but mount failed"
            return 1
        fi
    fi

    # Drop duplicate mounts of the SAME device elsewhere under /tmp/mnt.
    #
    # The firmware's automounter also mounts this volume. Whichever of us gets
    # there second finds /tmp/mnt/<LABEL> taken and falls back to
    # "/tmp/mnt/<LABEL>(1)", leaving one device mounted twice -- harmless to
    # the data (Linux shares the superblock) but it double-counts in df and in
    # the dashboard's disk list, and it gives torrents two plausible paths.
    # Our mount is the authoritative one because transmission's download-dir
    # is written against it.
    awk -v d="$_d" -v keep="$_mp" '$1 == d && $2 != keep && $2 ~ /^\/tmp\/mnt\// {print $2}' \
        /proc/mounts 2>/dev/null | while read -r _dup; do
        [ -n "$_dup" ] || continue
        if umount "$_dup" 2>/dev/null || umount -l "$_dup" 2>/dev/null; then
            log "removed duplicate mount of $_d at $_dup"
            rmdir "$_dup" 2>/dev/null
        fi
    done
    return 0
}

ensure_opt() {
    grep -q " /tmp/opt " /proc/mounts 2>/dev/null && return 0
    _mp=$(find_mp)
    [ -n "$_mp" ] || return 1
    [ -d "$_mp/entware" ] || return 1
    mkdir -p /tmp/opt
    mount -o bind "$_mp/entware" /tmp/opt 2>/dev/null || return 1
    log "bound $_mp/entware -> /tmp/opt"
    return 0
}

# Idempotent, and re-checked every pass: the firmware deletes this account
# whenever it regenerates /etc/passwd, which USB hotplug triggers.
# Sets READDED=1 when it had to recreate the account, so the caller knows a
# running sshd is now stale and must be restarted rather than left alone.
ensure_account() {
    READDED=0
    grep -q '^sshd:' /etc/passwd || {
        echo 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false' >> /etc/passwd
        READDED=1
    }
    grep -q '^sshd:' /etc/group || echo 'sshd:x:22:' >> /etc/group
    [ -d /var/empty ] || { mkdir -p /var/empty; chmod 755 /var/empty; }
    [ "$READDED" -eq 1 ] && log "sshd privsep account was missing, re-added"
    grep -q '^sshd:' /etc/passwd
}

# A live listener is NOT proof of a working sshd: if the account was deleted
# after sshd started, the socket still accepts and every child dies at
# privsep. So restart whenever the account had to be re-added.
ensure_sshd() {
    [ -x /opt/sbin/sshd ] || return 1
    if [ "$1" = "force" ] || ! pidof sshd >/dev/null 2>&1; then
        killall sshd 2>/dev/null
        sleep 1
        /opt/sbin/sshd -t 2>>"$LOG" || { log "sshd config test failed"; return 1; }
        /opt/sbin/sshd 2>>"$LOG" && log "sshd started, pid $(pidof sshd)"
    fi
    pidof sshd >/dev/null 2>&1
}

log "=== services start, uptime $(cut -d' ' -f1 /proc/uptime) ==="

# Wait for br0 to hold the LAN address: sshd binds it explicitly.
LANIP=$(nvram get lan_ipaddr 2>/dev/null); [ -z "$LANIP" ] && LANIP=192.168.1.1
i=0
while [ "$i" -lt 30 ]; do
    ifconfig br0 2>/dev/null | grep -q "$LANIP" && break
    sleep 2
    i=$((i + 1))
done

# --- maintenance loop -----------------------------------------------------
#
# Runs for the life of the boot. Cheap: two greps and a mount check per pass.
first=1
while :; do
    ensure_opt
    ensure_data_mount

    if ensure_account; then
        # A re-added account means any running sshd is now stale: its listener
        # survives but every child dies at privsep. Force a restart in that
        # case; otherwise only start it if it is not running at all.
        if [ "$READDED" -eq 1 ]; then
            ensure_sshd force
        else
            ensure_sshd
        fi
    fi

    # Converged = /opt bound and sshd actually running.
    if grep -q " /tmp/opt " /proc/mounts 2>/dev/null && pidof sshd >/dev/null 2>&1; then
        if [ "$first" -eq 1 ]; then
            log "initial setup complete, uptime $(cut -d' ' -f1 /proc/uptime)"
            first=0
        fi
        sleep "$INTERVAL"
    else
        sleep "$INTERVAL_FAST"
    fi
done
