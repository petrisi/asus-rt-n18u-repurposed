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
    # The live data lives in tmpfs, outside the document root.
    echo "alias.url            = ( \"/status.json\" => \"$JSON\" )"
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

collector_running() { pidof portal_collector.sh >/dev/null 2>&1; }

start_collector() {
    [ -x "$PORTAL/portal_collector.sh" ] || { log "collector missing"; return 1; }
    nohup "$PORTAL/portal_collector.sh" >/dev/null 2>&1 &
    log "collector started, pid $!"
}

kill_collector() { killall portal_collector.sh 2>/dev/null; }

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

    if [ -f "$JSON" ]; then
        _now=$(date +%s)
        _mod=$(date -r "$JSON" +%s 2>/dev/null)
        if [ -z "$_mod" ]; then
            # busybox date without -r: fall back to process check only
            collector_running || { log "collector gone, restarting"; start_collector; }
        else
            _age=$((_now - _mod))
            if [ "$_age" -gt "$STALE" ]; then
                log "status.json stale (${_age}s), restarting collector"
                kill_collector; sleep 1; start_collector
            fi
        fi
    else
        collector_running || { log "no status.json and no collector, starting"; start_collector; }
    fi

    ensure_fw
done
