#!/bin/sh
#
# Detached latency probe for the RRD history layer.
#
# Runs on its own, writes /tmp/portal/ping.kv, and rrd_feeder.sh reads that
# file on its NEXT pass. Results are therefore up to a minute old, which is
# irrelevant for a trend line and is the entire point: three ICMP probes is
# ~18s worst case, and a black-holed target is unbounded in practice even
# with -W. The 60s sampling loop must never wait on that.
#
# Self-locking, because the supervisor may fire it again while a probe against
# a dead target is still running.

RUN=/tmp/portal
KV="$RUN/ping.kv"
LOCKDIR="$RUN/.ping.lock"
TARGET=${1:-1.1.1.1}
COUNT=3
WAIT=2
STALE_LOCK=300

mkdir -p "$RUN" 2>/dev/null

# mkdir is atomic on every filesystem that matters, unlike test-then-touch.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Break a lock left behind by a killed probe, but only once it is clearly
    # older than any real run could be.
    _lt=$(date -r "$LOCKDIR" +%s 2>/dev/null)
    if [ -n "$_lt" ] && [ $(( $(date +%s) - _lt )) -gt "$STALE_LOCK" ]; then
        rmdir "$LOCKDIR" 2>/dev/null
        mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

probe() {
    ping -c "$COUNT" -W "$WAIT" "$TARGET" 2>/dev/null | awk '
        /packet loss/ {
            for (i = 1; i <= NF; i++) if ($i ~ /%$/) { sub(/%$/, "", $i); loss = $i }
        }
        # busybox: "round-trip min/avg/max = 7.103/7.370/7.637 ms"
        /round-trip|rtt/ {
            n = split($0, a, "=")
            if (n > 1) { split(a[2], b, "/"); rtt = b[2] + 0 }
        }
        END {
            printf "P_RTT=%s\nP_LOSS=%s\n",
                   (rtt == "" ? "U" : rtt),
                   (loss == "" ? "U" : loss)
        }'
}

out=$(probe)

# A probe that produced nothing at all is 100% loss with unknown latency --
# distinct from "no data", which is what an absent file would mean.
case "$out" in
    *P_LOSS=U*|"") out="P_RTT=U
P_LOSS=100" ;;
esac

printf '%s\n' "$out" > "$KV.tmp" 2>/dev/null && mv "$KV.tmp" "$KV" 2>/dev/null
exit 0
