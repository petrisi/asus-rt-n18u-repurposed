#!/bin/sh
# Transmission daemon stage -- OPTIONAL, and isolated like the RRD layer.
#
# Invoked from /jffs/usbmount.sh. TO DISABLE: delete this file; the caller is
# [ -x ] guarded and nothing else depends on it.
#
# Three rules, all of them learned rather than assumed:
#
# 1. NEVER START WITHOUT THE DATA VOLUME ACTUALLY MOUNTED.
#    If download-dir resolves into tmpfs because the disk is missing,
#    Transmission downloads into RAM, appears to work, and eventually takes
#    the router down. The mount is re-checked before EVERY start, not once.
#
# 2. LAUNCH THE BINARY DIRECTLY, NOT VIA /opt/etc/init.d.
#    rc.func discards stderr, so a failed start is completely invisible -- and
#    on this platform it will fail, because rc exports LD_LIBRARY_PATH pointing
#    at the firmware's libraries and every Entware binary then loads the wrong
#    libc and dies silently.
#
# 3. A SLOW START IS NOT A FAILED START.
#    On slow USB storage the daemon can take 20s+ to appear. Waiting three
#    seconds, declaring failure and letting the next pass launch a second
#    instance gives you two daemons fighting over the config lock, both dying,
#    every interval, indefinitely. Hence the lock and the patient wait.

DATA_LABEL=BTDATA
DATA_MP="/tmp/mnt/$DATA_LABEL"
DL_DIR="$DATA_MP/torrents/complete"
BIN=/opt/bin/transmission-daemon
CFG=/opt/etc/transmission
LOG=/jffs/transmission.log
LOCKDIR=/tmp/transmission.lock.d
PEER_PORT=51413
# Same reasoning as services.sh: poll fast until the daemon is up (this stage
# waits on /opt, which another stage provides at an unpredictable time), then
# back off to a cheap heartbeat.
INTERVAL_FAST=10
INTERVAL=60
STARTWAIT=40

WANIF=$(nvram get wan0_ifname 2>/dev/null); [ -z "$WANIF" ] && WANIF=eth0

# Single instance: script_usbmount fires on every USB mount event.
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && rm -f "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

unset LD_LIBRARY_PATH LD_PRELOAD

# NOTE: the binary lives under /opt, which is a bind mount that services.sh
# establishes at ~40s uptime. This stage is launched from the same hook and
# races it, so an early "[ -x $BIN ] || exit 0" here exits permanently and the
# seedbox never starts -- observed across a reboot. The check belongs INSIDE
# the loop: wait for the dependency rather than asserting it once.

# The peer port must be reachable on both address families. ip6tables is a
# SEPARATE table -- a v4-only rule set means a dual-stack seed quietly serves
# no v6 peers at all. UDP matters as much as TCP: uTP and DHT both use it.
# Idempotent: delete before insert so passes cannot stack duplicates.
ensure_fw() {
    for proto in tcp udp; do
        iptables  -D INPUT -i "$WANIF" -p $proto --dport "$PEER_PORT" -j ACCEPT 2>/dev/null
        iptables  -I INPUT 1 -i "$WANIF" -p $proto --dport "$PEER_PORT" -j ACCEPT 2>/dev/null
        ip6tables -D INPUT -i "$WANIF" -p $proto --dport "$PEER_PORT" -j ACCEPT 2>/dev/null
        ip6tables -I INPUT 1 -i "$WANIF" -p $proto --dport "$PEER_PORT" -j ACCEPT 2>/dev/null
    done
}

running() { pidof transmission-daemon >/dev/null 2>&1; }

start_daemon() {
    # Rule 1. Checked every time, deliberately.
    if ! grep -q " $DATA_MP " /proc/mounts 2>/dev/null; then
        log "REFUSING to start: $DATA_MP is not mounted (download-dir would fall into tmpfs)"
        return 1
    fi
    [ -d "$DL_DIR" ] || mkdir -p "$DL_DIR" 2>/dev/null
    [ -d "$DL_DIR" ] || { log "REFUSING to start: $DL_DIR missing"; return 1; }

    log "starting transmission-daemon"
    "$BIN" -g "$CFG" >>"$LOG" 2>&1

    # Rule 3: wait patiently rather than assuming a slow start failed.
    _n=0
    while [ "$_n" -lt "$STARTWAIT" ]; do
        running && { log "transmission-daemon up, pid $(pidof transmission-daemon)"; return 0; }
        sleep 1
        _n=$((_n + 1))
    done
    log "transmission-daemon did not appear within ${STARTWAIT}s"
    return 1
}

log "=== transmission stage start, uptime $(cut -d' ' -f1 /proc/uptime) ==="

_warned=0
while :; do
    if [ ! -x "$BIN" ]; then
        # /opt not bound yet (or transmission not installed). Keep waiting.
        [ "$_warned" -eq 0 ] && { log "waiting for $BIN to become available"; _warned=1; }
    else
        [ "$_warned" -eq 1 ] && { log "$BIN available"; _warned=0; }
        running || start_daemon
        ensure_fw
    fi
    if running; then sleep "$INTERVAL"; else sleep "$INTERVAL_FAST"; fi
done
