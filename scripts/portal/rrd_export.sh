#!/bin/sh
#
# RRD -> JSON for the browser. OPTIONAL layer; silent no-op without the stick.
#
# rrdtool 1.2 predates JSON export, so this converts `rrdtool fetch` output
# with awk and writes static files that lighttpd serves from tmpfs.
#
# TWO NON-OBVIOUS REQUIREMENTS, both learned the hard way:
#
# 1. SAMPLES GO ON A FIXED TIME GRID, INDEXED BY TIMESTAMP.
#    `rrdtool fetch` returns rows only from where each database actually
#    starts. A database created ten minutes ago yields a handful of rows for a
#    seven-day request while an older one yields the full set. Appending in
#    order produces series of different lengths drawn against one shared
#    x-axis -- every young series stretched across the whole chart, silently
#    misaligned. Rows are placed into slots computed from start/step.
#
# 2. THE PAYLOAD IS NEVER ACCUMULATED IN A SHELL VARIABLE.
#    busybox caps arguments to its builtins at roughly 128 KB, and
#    [ -n "$big" ] then fails with "Argument list too long" and returns
#    non-zero -- which reads exactly like "empty". Fragments are streamed
#    through files and tested with [ -s file ], a size test rather than an
#    argument test.

RUN=/tmp/portal
USB_LABEL=ROUTERDATA
USB_MP="/tmp/mnt/$USB_LABEL"
RRD_DIR="$USB_MP/rrd"
RRDTOOL=/opt/bin/rrdtool
TMPD="$RUN/.rrdexp"

unset LD_LIBRARY_PATH LD_PRELOAD

# Windows: name, seconds back, resolution in seconds.
ALL_WINDOWS="24h:86400:60 7d:604800:300 30d:2592000:1800"

# Optional argument selects ONE window. A full export of all three takes ~12s
# of solid awk on this single-core CPU, which is a visible spike on the live
# dashboard if run every 5 minutes. portal_start.sh therefore staggers them:
# 24h often, 7d and 30d rarely, since a 30-minute-resolution series does not
# change meaningfully between hourly exports.
if [ -n "$1" ]; then
    WINDOWS=""
    for _w in $ALL_WINDOWS; do
        [ "${_w%%:*}" = "$1" ] && WINDOWS="$_w"
    done
    [ -n "$WINDOWS" ] || exit 0
else
    WINDOWS="$ALL_WINDOWS"
fi
RRDS="sys net wifi fw ping"

# If the source is gone, remove the exports. Stale JSON left in tmpfs renders
# as though it were current; absent data must look absent.
cleanup_exports() {
    for w in $ALL_WINDOWS; do
        rm -f "$RUN/hist_${w%%:*}.json" 2>/dev/null
    done
}

[ -x "$RRDTOOL" ] || { cleanup_exports; exit 0; }
grep -q " $USB_MP " /proc/mounts 2>/dev/null || { cleanup_exports; exit 0; }
[ -d "$RRD_DIR" ] || { cleanup_exports; exit 0; }

mkdir -p "$TMPD" 2>/dev/null || exit 0

# Emit `"ds":[v,v,null,...]` fragments for one RRD onto a fixed grid.
fetch_json() {
    _rrd="$1"; _start="$2"; _end="$3"; _res="$4"
    [ -f "$_rrd" ] || return 1
    $RRDTOOL fetch "$_rrd" AVERAGE -r "$_res" -s "$_start" -e "$_end" 2>/dev/null | awk -v st="$_start" -v en="$_end" -v res="$_res" '
        NR == 1 {
            nds = NF
            for (i = 1; i <= NF; i++) name[i] = $i
            # Slot count is derived from the REQUESTED window, not from the
            # number of rows returned. That is the whole point.
            slots = int((en - st) / res)
            next
        }
        /^[0-9]+:/ {
            ts = $1; sub(/:$/, "", ts)
            k = int((ts - st) / res)
            if (k < 0 || k > slots) next
            for (i = 1; i <= nds; i++) {
                v = $(i + 1)
                seen[k, i] = 1
                val[k, i] = (v == "nan" || v == "-nan" || v == "" ) ? "null" : v + 0
            }
        }
        END {
            for (i = 1; i <= nds; i++) {
                printf "\"%s\":[", name[i]
                for (k = 0; k <= slots; k++) {
                    if (k) printf ","
                    printf "%s", (seen[k, i] ? val[k, i] : "null")
                }
                printf "]"
                if (i < nds) printf ","
            }
        }'
}

now=$(date +%s)

for spec in $WINDOWS; do
    name=${spec%%:*}
    rest=${spec#*:}
    back=${rest%%:*}
    res=${rest##*:}

    # Align start/end to the resolution so slots line up with rrdtool's own
    # consolidation boundaries.
    end=$(( (now / res) * res ))
    start=$(( end - back ))

    frag="$TMPD/$name.frag"
    : > "$frag"

    first=1
    for r in $RRDS; do
        out="$TMPD/$name.$r"
        if fetch_json "$RRD_DIR/$r.rrd" "$start" "$end" "$res" > "$out" 2>/dev/null && [ -s "$out" ]; then
            [ "$first" -eq 1 ] || printf ',' >> "$frag"
            cat "$out" >> "$frag"
            first=0
        fi
        rm -f "$out"
    done

    dest="$RUN/hist_$name.json"
    if [ -s "$frag" ]; then
        {
            printf '{"start":%s,"end":%s,"step":%s,"series":{' "$start" "$end" "$res"
            cat "$frag"
            printf '}}\n'
        } > "$dest.tmp" 2>/dev/null && mv "$dest.tmp" "$dest" 2>/dev/null
    else
        # No usable data for this window: remove rather than leave the last
        # good export lying around looking current.
        rm -f "$dest" 2>/dev/null
    fi
    rm -f "$frag"
done

rmdir "$TMPD" 2>/dev/null
exit 0
