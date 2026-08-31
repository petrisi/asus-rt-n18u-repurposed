#!/bin/sh
#
# RRD history feeder -- OPTIONAL layer for the status portal.
#
# ============================ DESIGN CONSTRAINTS ============================
#
# 1. THE CORE DASHBOARD MUST NOT DEPEND ON THIS.
#    rrdtool is an Entware binary on the USB stick. If the stick is absent this
#    script exits immediately and portal_collector.sh / status.json / the live
#    dashboard carry on unaffected. Only the History section degrades.
#
# 2. NO NEW SAMPLING OF HANG-PRONE INTERFACES.
#    Levels come from /tmp/portal/status.json, which portal_collector.sh
#    already produces and which already owns the bounded-read discipline for
#    wl ioctls. Duplicating that sampling here would duplicate the hazard.
#    Direct reads are limited to things that cannot block: flat /proc files
#    and iptables -n.
#
# 3. NO SHELL ARITHMETIC ON COUNTERS.
#    32-bit ARM userland; busybox ash truncates values >= 2^31 to zero
#    silently. Raw counters are passed to rrdtool AS STRINGS and rrdtool does
#    the maths in C. Do not compute deltas here.
#
# 4. GAPS MUST STAY VISIBLE.
#    Heartbeat 120s against a 60s step, and status.json is age-checked before
#    it is trusted. A wedged collector leaves a well-formed but OLD file;
#    feeding it would draw a flat line indistinguishable from an idle router.

RUN=/tmp/portal
STATUS="$RUN/status.json"
USB_LABEL=ROUTERDATA
# Resolve the volume's ACTUAL mountpoint rather than assuming /tmp/mnt/<LABEL>.
#
# The firmware's automounter sometimes lands the volume on "/tmp/mnt/<LABEL>(1)"
# -- observed after a reboot, with nothing else mounted at the plain name. When
# that happens a hardcoded path makes this script's mount check fail and it
# exits silently: no feeding, no export, and the dashboard reports "no history"
# while the databases sit intact a few characters away. services.sh has always
# resolved dynamically, which is why SSH and Entware kept working through it.
find_mp() {
    _dev=$(blkid 2>/dev/null | grep "LABEL=\"$USB_LABEL\"" | cut -d: -f1)
    [ -n "$_dev" ] || return 1
    awk -v d="$_dev" '$1==d {print $2; exit}' /proc/mounts
}
USB_MP=$(find_mp)
RRD_DIR="$USB_MP/rrd"
SYS="$RRD_DIR/sys.rrd"
NET="$RRD_DIR/net.rrd"
WIFI="$RRD_DIR/wifi.rrd"
FW="$RRD_DIR/fw.rrd"
PING="$RRD_DIR/ping.rrd"
PINGKV="$RUN/ping.kv"
RRDTOOL=/opt/bin/rrdtool
STEP=60
MAXAGE=150

WANIF=$(nvram get wan0_ifname 2>/dev/null); [ -z "$WANIF" ] && WANIF=eth0
LANIF=$(nvram get lan_ifname  2>/dev/null); [ -z "$LANIF" ] && LANIF=br0

# Entware binaries die silently if rc's LD_LIBRARY_PATH is inherited.
unset LD_LIBRARY_PATH LD_PRELOAD

# --- guards: every one of these is a silent, successful no-op -------------
[ -x "$RRDTOOL" ] || exit 0
[ -n "$USB_MP" ] || exit 0
grep -q " $USB_MP " /proc/mounts 2>/dev/null || exit 0
mkdir -p "$RRD_DIR" 2>/dev/null || exit 0

# --- schema ---------------------------------------------------------------
#
# DERIVE, not COUNTER, for byte and packet counters. COUNTER treats any
# decrease as a hardware wrap and synthesises an enormous rate; these counters
# reset to zero on reboot, which COUNTER renders as a ~1e10 B/s spike. DERIVE
# with min=0 records the decrease as UNKNOWN, which is the truth.
#
# Heartbeat is twice the step, so one missed sample records UNKNOWN rather
# than carrying the previous value forward.
RRA_SET='RRA:AVERAGE:0.5:1:1500 RRA:AVERAGE:0.5:5:2100 RRA:AVERAGE:0.5:30:1500 RRA:AVERAGE:0.5:360:1460'
RRA_MAX='RRA:MAX:0.5:1:1500 RRA:MAX:0.5:5:2100 RRA:MAX:0.5:30:1500 RRA:MAX:0.5:360:1460'

create_rrds() {
    [ -f "$SYS" ] || $RRDTOOL create "$SYS" --step $STEP \
        DS:cpu:GAUGE:120:0:100 \
        DS:temp:GAUGE:120:0:150 \
        DS:memused:GAUGE:120:0:U \
        DS:conn:GAUGE:120:0:U \
        DS:load1:GAUGE:120:0:U \
        $RRA_SET 2>/dev/null

    [ -f "$NET" ] || $RRDTOOL create "$NET" --step $STEP \
        DS:wanrx:DERIVE:120:0:U \
        DS:wantx:DERIVE:120:0:U \
        DS:lanrx:DERIVE:120:0:U \
        DS:lantx:DERIVE:120:0:U \
        $RRA_SET $RRA_MAX 2>/dev/null

    # noise floor is around -90 dBm. A GAUGE declared 0:U would discard every
    # single sample, silently.
    [ -f "$WIFI" ] || $RRDTOOL create "$WIFI" --step $STEP \
        DS:rtemp:GAUGE:120:0:150 \
        DS:noise:GAUGE:120:-120:0 \
        DS:clients:GAUGE:120:0:U \
        DS:rate:GAUGE:120:0:U \
        $RRA_SET 2>/dev/null

    [ -f "$FW" ] || $RRDTOOL create "$FW" --step $STEP \
        DS:indrop:DERIVE:120:0:U \
        DS:fwdrop:DERIVE:120:0:U \
        $RRA_SET 2>/dev/null

    [ -f "$PING" ] || $RRDTOOL create "$PING" --step $STEP \
        DS:rtt:GAUGE:120:0:U \
        DS:loss:GAUGE:120:0:100 \
        $RRA_SET 2>/dev/null
}
create_rrds

# --- status.json, age-checked --------------------------------------------
#
# A wedged collector leaves a perfectly well-formed file that is simply old.
# Record UNKNOWN rather than re-recording stale values as current.
fresh=0
if [ -f "$STATUS" ]; then
    _age=$(( $(date +%s) - $(date -r "$STATUS" +%s 2>/dev/null || echo 0) ))
    [ "$_age" -le "$MAXAGE" ] && fresh=1
fi

parse_status() {
    awk '
    function obj(name) {
        if (!match(line, "\"" name "\":\\{[^}]*\\}")) return ""
        return substr(line, RSTART, RLENGTH)
    }
    function fld(o, key,   s) {
        if (o == "") return "U"
        if (!match(o, "\"" key "\":-?[0-9]+(\\.[0-9]+)?")) return "U"
        s = substr(o, RSTART, RLENGTH)
        sub(/^[^:]*:/, "", s)
        return s
    }
    { line = line $0 }
    END {
        c = obj("cpu")
        printf "P_CPU=%s\n",  fld(c, "pct")
        printf "P_TEMP=%s\n", fld(c, "temp")

        # load is an ARRAY here: "load":[0.70,0.37,0.14]
        if (match(line, "\"load\":\\[[0-9.,]+\\]")) {
            s = substr(line, RSTART, RLENGTH); gsub(/[^0-9.,]/, "", s)
            n = split(s, L, ",")
            printf "P_LOAD1=%s\n", (n > 0 ? L[1] : "U")
        } else printf "P_LOAD1=U\n"

        m = obj("mem")
        mt = fld(m, "total"); mf = fld(m, "free")
        mb = fld(m, "buffers"); mc = fld(m, "cached")
        # "used" excludes buffers and cache: what actually constrains the box.
        if (mt == "U" || mf == "U" || mb == "U" || mc == "U")
            printf "P_MEMU=U\n"
        else
            printf "P_MEMU=%s\n", mt - mf - mb - mc

        printf "P_CONN=%s\n", fld(obj("ct"), "n")

        w = obj("wifi")
        printf "P_WTEMP=%s\n",   fld(w, "temp")
        printf "P_WNOISE=%s\n",  fld(w, "noise")
        printf "P_WCLI=%s\n",    fld(w, "clients")
        printf "P_WRATE=%s\n",   fld(w, "rate")
    }' "$STATUS" 2>/dev/null
}

P_CPU=U; P_TEMP=U; P_LOAD1=U; P_MEMU=U; P_CONN=U
P_WTEMP=U; P_WNOISE=U; P_WCLI=U; P_WRATE=U
if [ "$fresh" -eq 1 ]; then
    eval "$(parse_status)"
fi

# --- direct reads: flat /proc and iptables only, never wl ------------------
#
# Raw cumulative counters, passed through as strings. rrdtool computes the
# rate; the shell must not.
net_raw=$(awk -v w="$WANIF" -v l="$LANIF" '
    { gsub(/:/, " ")
      if ($1 == w) { wr = $2; wt = $10 }
      if ($1 == l) { lr = $2; lt = $10 } }
    END { printf "%s %s %s %s",
          (wr == "" ? "U" : wr), (wt == "" ? "U" : wt),
          (lr == "" ? "U" : lr), (lt == "" ? "U" : lt) }' /proc/net/dev)
set -- $net_raw; N_WR=$1; N_WT=$2; N_LR=$3; N_LT=$4

fw_raw=$(iptables -L -n -v -x 2>/dev/null | awk '
    /^Chain INPUT/   { c = "i"; next }
    /^Chain FORWARD/ { c = "f"; next }
    /^Chain /        { c = "";  next }
    c == "i" && $3 == "DROP" { ip += $1 }
    c == "f" && $3 == "DROP" { fp += $1 }
    END { printf "%s %s", (ip == "" ? 0 : ip), (fp == "" ? 0 : fp) }')
set -- $fw_raw; F_IN=$1; F_FW=$2
[ -z "$F_IN" ] && F_IN=U
[ -z "$F_FW" ] && F_FW=U

# --- latency, produced by the detached prober on its own schedule ---------
#
# Read from a file rather than probed here: three ICMP probes is ~18s worst
# case and a black-holed target is unbounded in practice, which must never
# block a 60s sampling loop. Results are up to a minute old, which does not
# matter for a trend line.
P_RTT=U; P_LOSS=U
[ -f "$PINGKV" ] && . "$PINGKV" 2>/dev/null

$RRDTOOL update "$SYS"  "N:$P_CPU:$P_TEMP:$P_MEMU:$P_CONN:$P_LOAD1" 2>/dev/null
$RRDTOOL update "$NET"  "N:$N_WR:$N_WT:$N_LR:$N_LT"                 2>/dev/null
$RRDTOOL update "$WIFI" "N:$P_WTEMP:$P_WNOISE:$P_WCLI:$P_WRATE"     2>/dev/null
$RRDTOOL update "$FW"   "N:$F_IN:$F_FW"                             2>/dev/null
$RRDTOOL update "$PING" "N:$P_RTT:$P_LOSS"                          2>/dev/null

exit 0
