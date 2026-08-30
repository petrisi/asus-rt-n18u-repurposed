#!/bin/sh
# Starts and supervises the status portal: lighttpd (static) + the collector.
#
# TO DISABLE: delete /jffs/portal/portal_start.sh (the caller is [ -x ] guarded).
#
# This stage is deliberately independent of Entware and of the USB stick at
# RUNTIME: it uses the firmware's own /usr/sbin/lighttpd and writes only to
# tmpfs, so pulling the stick leaves the dashboard working.
#
# It is NOT independent of USB at STARTUP, because script_usbmount is the only
# boot hook this model has. That is a property of the platform, not a choice.
# See docs/02-persistence.md.

PORTAL=/jffs/portal
RUN=/tmp/portal
CONF="$RUN/lighttpd.conf"
PIDF="$RUN/lighttpd.pid"
JSON="$RUN/status.json"
STALE=150          # seconds without a status.json update before restarting the collector
PORT=8080          # NOT 80: ASUS httpd owns port 80 on the LAN address and loopback
AUTHFILE="$PORTAL/.htdigest"   # deliberately NOT under www/ (would be downloadable)
REALM=rtn18u
POLL=30

LANIP=$(nvram get lan_ipaddr 2>/dev/null); [ -z "$LANIP" ] && LANIP=192.168.1.1
WANIF=$(nvram get wan0_ifname 2>/dev/null); [ -z "$WANIF" ] && WANIF=eth0

mkdir -p "$RUN"

log() { echo "$(date '+%F %T') $*" >> "$RUN/portal.log"; }

# Single instance. script_usbmount fires on EVERY USB mount event, not just at
# boot, so plugging in a second disk previously started a rival supervisor:
# two loops each killing and restarting the other's lighttpd and collector.
# Observed with pids 480 and 467 running simultaneously.
if ! mkdir "$RUN/.portal.lock.d" 2>/dev/null; then
    log "another portal_start.sh is already running, exiting"
    exit 0
fi
trap 'rmdir "$RUN/.portal.lock.d" 2>/dev/null' EXIT INT TERM

# lighttpd modules live in /usr/lib on this firmware, NOT /usr/lib/lighttpd,
# which is the default the binary would otherwise look in.
write_conf() {
    {
    echo "server.document-root = \"$PORTAL/www\""
    echo "server.port          = $PORT"
    # Bind the LAN address explicitly. A 0.0.0.0 bind would also expose this on
    # the WAN interface; the firewall rule below is then belt-and-braces only.
    echo "server.bind          = \"$LANIP\""
    echo "server.modules-dir   = \"/usr/lib\""
    echo "server.modules       = ( \"mod_access\", \"mod_alias\", \"mod_auth\" )"  # indexfile/staticfile are compiled in on this build
    echo "server.pid-file      = \"$PIDF\""
    echo "server.errorlog      = \"$RUN/lighttpd.error.log\""
    echo "index-file.names     = ( \"index.html\" )"
    echo "mimetype.assign      = ( \".html\" => \"text/html; charset=utf-8\", \".json\" => \"application/json\", \".css\" => \"text/css\", \".js\" => \"application/javascript\" )"
    # The live data and the exported history live in tmpfs, outside the
    # document root. The history files are absent whenever the USB stick or
    # rrdtool is missing -- the page treats a 404 as "no history", which is
    # correct, so no conditional is needed here.
    echo "alias.url            = ( \"/status.json\" => \"$JSON\", \"/hist_24h.json\" => \"$RUN/hist_24h.json\", \"/hist_7d.json\" => \"$RUN/hist_7d.json\", \"/hist_30d.json\" => \"$RUN/hist_30d.json\" )"
    # Never serve dotfiles -- the digest file lives outside www/ anyway, but
    # this closes the class of mistake rather than the instance.
    echo "url.access-deny      = ( \"~\", \".inc\", \".htdigest\" )"
    if [ -s "$AUTHFILE" ]; then
        echo "auth.backend                   = \"htdigest\""
        echo "auth.backend.htdigest.userfile = \"$AUTHFILE\""
        # Digest, not basic: this is plain HTTP, and basic auth would put the
        # password on the wire with every single request. The realm is part of
        # the hash -- change it here and every existing line in .htdigest stops
        # matching, silently.
        echo "auth.require = ( \"/\" => ( \"method\" => \"digest\", \"realm\" => \"$REALM\", \"require\" => \"valid-user\" ) )"
    fi
    } > "$CONF"
}

# Accept the port on the LAN bridge, drop it on WAN. Idempotent: rules are
# deleted before being re-added, so repeated supervision passes cannot stack
# duplicates up.
ensure_fw() {
    iptables -D INPUT -i "$WANIF" -p tcp --dport "$PORT" -j DROP 2>/dev/null
    iptables -I INPUT -i "$WANIF" -p tcp --dport "$PORT" -j DROP 2>/dev/null
    ip6tables -D INPUT -i "$WANIF" -p tcp --dport "$PORT" -j DROP 2>/dev/null
    ip6tables -I INPUT -i "$WANIF" -p tcp --dport "$PORT" -j DROP 2>/dev/null
}

# Run a job at most every $2 seconds, never overlapping itself.
#
# The stamp file paces it; the lock directory guarantees a slow run is not
# launched twice. Both are needed: pacing alone breaks down as soon as a run
# takes longer than its interval, which the 30d export can. Jobs run in the
# background so a slow export never stalls the supervision loop -- lighttpd
# and collector recovery must stay responsive.
run_gated() {
    _n=$1; _int=$2; shift 2
    _stamp="$RUN/.stamp.$_n"; _lock="$RUN/.lock.$_n"
    _now=$(date +%s); _last=0
    [ -f "$_stamp" ] && _last=$(cat "$_stamp" 2>/dev/null)
    [ -z "$_last" ] && _last=0
    [ $(( _now - _last )) -ge "$_int" ] || return 0
    mkdir "$_lock" 2>/dev/null || return 0     # previous run still in flight
    echo "$_now" > "$_stamp"
    ( "$@" >/dev/null 2>&1; rmdir "$_lock" 2>/dev/null ) &
}

# The optional history layer. Every one of these scripts is a silent no-op
# when the USB stick or rrdtool is absent, so this needs no guard of its own
# and the live dashboard is unaffected either way.
#
# Intervals are 55s rather than 60s because the supervision loop polls every
# $POLL (30s): at 60 the gate would alternate between 60s and 90s cadence,
# and 90s against a 120s heartbeat leaves very little margin.
ensure_rrd() {
    run_gated feeder   55 "$PORTAL/rrd_feeder.sh"
    run_gated ping     55 "$PORTAL/rrd_ping.sh"
    # Staggered: a full export is ~12s of solid awk on one core. The coarse
    # windows barely change between runs, so they run rarely.
    run_gated exp24h  300 "$PORTAL/rrd_export.sh" 24h
    run_gated exp7d   900 "$PORTAL/rrd_export.sh" 7d
    run_gated exp30d 3600 "$PORTAL/rrd_export.sh" 30d
}

collector_running() { pidof portal_collector.sh >/dev/null 2>&1; }

start_collector() {
    [ -x "$PORTAL/portal_collector.sh" ] || { log "collector missing"; return 1; }
    nohup "$PORTAL/portal_collector.sh" >/dev/null 2>&1 &
    log "collector started, pid $!"
}

# SIGTERM first, then SIGKILL. The second is not belt-and-braces: a collector
# hung by SIGSTOP never handles SIGTERM and stays in state T indefinitely, so
# a TERM-only kill LEAKS one stopped process per hang and pidof keeps matching
# it. SIGKILL is delivered regardless of stop state. Found by kill -STOP
# testing, not by reasoning.
kill_collector() {
    killall portal_collector.sh 2>/dev/null
    sleep 1
    killall -9 portal_collector.sh 2>/dev/null
}

lighttpd_running() { pidof lighttpd >/dev/null 2>&1; }

start_lighttpd() {
    write_conf
    if /usr/sbin/lighttpd -t -f "$CONF" >/dev/null 2>&1; then
        /usr/sbin/lighttpd -f "$CONF" 2>>"$RUN/portal.log" && log "lighttpd started on $LANIP:$PORT"
    else
        log "FATAL: lighttpd config test failed"
        /usr/sbin/lighttpd -t -f "$CONF" >>"$RUN/portal.log" 2>&1
        return 1
    fi
}

# ---- stop anything we started previously, then start clean ----
kill_collector
killall lighttpd 2>/dev/null
sleep 1

log "=== portal start, uptime $(cut -d' ' -f1 /proc/uptime) ==="
[ -s "$AUTHFILE" ] || log "NOTE: $AUTHFILE absent -- dashboard is unauthenticated on the LAN"
start_lighttpd
start_collector
ensure_fw
ensure_rrd

# ---- supervision loop ----
#
# Liveness is judged by DATA FRESHNESS, not by process existence. A wedged
# collector stays in the process table indefinitely; an earlier version of the
# sibling project sat happily for three days with a hung collector because it
# only asked "is the pid alive?". The page reports staleness rather than
# showing a frozen chart that looks live.
while :; do
    sleep "$POLL"

    lighttpd_running || { log "lighttpd not running, restarting"; start_lighttpd; }

    # Two independent signals, because they catch different failures:
    #   - process absent  -> the collector DIED. Caught immediately.
    #   - data stale      -> the collector HUNG. It is still in the process
    #                        table and still serving a valid, frozen file, so
    #                        only the timestamp reveals it.
    # Checking only the first is the mistake the sibling project made (three
    # days of frozen graphs). Checking only the second leaves a dead collector
    # unnoticed for up to $STALE seconds.
    if ! collector_running; then
        log "collector process gone, restarting"
        start_collector
    elif [ -f "$JSON" ]; then
        _now=$(date +%s)
        _mod=$(date -r "$JSON" +%s 2>/dev/null)
        if [ -n "$_mod" ]; then
            _age=$((_now - _mod))
            if [ "$_age" -gt "$STALE" ]; then
                log "status.json stale (${_age}s) but collector alive - hung, restarting"
                kill_collector; sleep 1; start_collector
            fi
        fi
    fi

    ensure_rrd
    ensure_fw
done
