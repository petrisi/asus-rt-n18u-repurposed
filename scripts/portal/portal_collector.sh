#!/bin/sh
# Samples RT-N18U telemetry into /tmp/portal/status.json
#
# Writes to /tmp (tmpfs/RAM) deliberately -- NOT /jffs. At a 2s interval this is
# ~43k writes/day; putting that on NAND would wear it out for no reason.
#
# *** ALL COUNTER ARITHMETIC IS DONE IN AWK, NOT THE SHELL. ***
#
# This userland is 32-bit ARM and busybox ash arithmetic silently truncates any
# value >= 2^31 to ZERO -- no error, no warning:
#     rx=18821963980 ; echo $((rx + 1))   ->  1
# Interface byte counters pass 2 GB within hours of real traffic, so shell-based
# deltas produce a permanent 0 for the busier direction while the quieter one
# still looks correct -- which reads as swapped labels, not as a bug.
# awk uses doubles and is exact to 2^53, so every delta is computed there.

RUN=/tmp/portal
JSON="$RUN/status.json"
TMP="$RUN/.status.tmp"
INTERVAL=2
SLOWMOD=15                 # 15 x 2s = every 30s for the expensive samples

WANIF=$(nvram get wan0_ifname 2>/dev/null); [ -z "$WANIF" ] && WANIF=eth0
LANIF=$(nvram get lan_ifname  2>/dev/null); [ -z "$LANIF" ] && LANIF=br0
WLIF=$(nvram  get wl0_ifname  2>/dev/null); [ -z "$WLIF"  ] && WLIF=eth1

# This model has no /sys/class/thermal. The Northstar SoC exposes CPU
# temperature here instead, as "CPU temperature\t: 66'C".
THERMAL=/proc/dmu/temperature
LEASES=/var/lib/misc/dnsmasq.leases
CT_COUNT=/proc/sys/net/netfilter/nf_conntrack_count
CT_MAX=/proc/sys/net/netfilter/nf_conntrack_max

mkdir -p "$RUN"

# Device identity -- read once, so the page carries no hardcoded assumptions.
h_model=$(nvram get productid);  [ -z "$h_model" ] && h_model="router"
h_name=$(cat /proc/sys/kernel/hostname 2>/dev/null); [ -z "$h_name" ] && h_name="$h_model"
h_lan=$(nvram get lan_ipaddr)
h_mask=$(nvram get lan_netmask)
h_fw="$(nvram get firmver).$(nvram get buildno)_$(nvram get extendno)"

d_on=$(nvram get dhcp_enable_x); [ -z "$d_on" ] && d_on=0
d_st=$(nvram get dhcp_start);    d_en=$(nvram get dhcp_end)
d_ls=$(nvram get dhcp_lease);    [ -z "$d_ls" ] && d_ls=0

# ---- raw snapshot helpers: emit space-separated counters, no arithmetic ----
snap_cpu() { awk '/^cpu /{printf "%.0f %.0f", $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat; }
snap_net() { awk -v w="$WANIF" -v l="$LANIF" '
               { gsub(/:/, " ")
                 if ($1 == w) { wr = $2; wt = $10 }
                 if ($1 == l) { lr = $2; lt = $10 } }
               END { printf "%.0f %.0f %.0f %.0f", wr+0, wt+0, lr+0, lt+0 }' /proc/net/dev; }
snap_sys() { awk '/^ctxt /{c=$2} /^intr /{i=$2} /^procs_running/{r=$2}
                  END{printf "%.0f %.0f %.0f", c+0, i+0, r+0}' /proc/stat; }
snap_fw()  { iptables -L -n -v -x 2>/dev/null | awk '
               /^Chain INPUT/   { c = "i"; next }
               /^Chain FORWARD/ { c = "f"; next }
               /^Chain /        { c = "";  next }
               c == "i" && $3 == "DROP" { ip += $1; ib += $2 }
               c == "f" && $3 == "DROP" { fp += $1; fb += $2 }
               END { printf "%.0f %.0f %.0f %.0f", ip+0, ib+0, fp+0, fb+0 }'; }

# Bounded wl call. wl ioctls can block indefinitely against this driver, and a
# hung collector is worse than a missing field: it freezes every value on the
# page while still looking alive. 5s ceiling, then SIGKILL.
# There is no `timeout` applet in this busybox, hence the manual poll.
wl_to() {
    _if=$1; shift
    : > "$RUN/.wl"
    wl -i "$_if" "$@" > "$RUN/.wl" 2>/dev/null &
    _p=$!; _n=0
    while kill -0 "$_p" 2>/dev/null; do
        [ "$_n" -ge 50 ] && { kill -9 "$_p" 2>/dev/null; break; }
        usleep 100000; _n=$((_n + 1))
    done
    wait "$_p" 2>/dev/null
    cat "$RUN/.wl" 2>/dev/null
}

json_escape() { sed 's/\\/\\\\/g; s/"/\\"/g' ; }

# ---- slow-path samples (every SLOWMOD ticks) ----
s_wtemp=0; s_wrate=""; s_wnoise=0; s_wchan=0; s_wup=0; s_clients=0
s_leases="[]"; s_disks="[]"; s_opt=0

slow_sample() {
    s_wchan=$(wl_to "$WLIF" channel | awk '/current mac channel/{print $NF+0; exit}')
    [ -z "$s_wchan" ] && s_wchan=0
    s_wtemp=$(wl_to "$WLIF" phy_tempsense | awk '{print $1+0; exit}')
    [ -z "$s_wtemp" ] && s_wtemp=0
    s_wnoise=$(wl_to "$WLIF" noise | awk '{print $1+0; exit}')
    [ -z "$s_wnoise" ] && s_wnoise=0
    s_wrate=$(wl_to "$WLIF" rate | awk '{print $1+0; exit}')
    [ -z "$s_wrate" ] && s_wrate=0
    [ "$(wl_to "$WLIF" bss | head -1)" = "up" ] && s_wup=1 || s_wup=0
    s_clients=$(wl_to "$WLIF" assoclist | grep -c "^assoclist")

    # DHCP leases.
    #
    # FIELD 1 IS SECONDS REMAINING, NOT AN ABSOLUTE EXPIRY. Standard dnsmasq
    # writes an absolute epoch there, but this router has no RTC, so ASUS
    # builds dnsmasq with HAVE_BROKEN_RTC, which stores the remaining lease
    # time instead. Treating it as an epoch renders every lease as January
    # 1970 -- which is exactly what it looked like.
    #
    # Emit both: "r" is the honest datum (remaining seconds, correct even when
    # the clock is wrong), "e" is the absolute expiry derived from the router's
    # current time for convenience. A 0 means an infinite/static lease.
    if [ -s "$LEASES" ]; then
        s_leases=$(awk -v now="$(date +%s)" 'BEGIN{printf "["; n=0}
            NF>=4 { if(n++)printf ","
                    name=$4; if(name=="*")name="";
                    rem=$1+0;
                    printf "{\"r\":%.0f,\"e\":%.0f,\"m\":\"%s\",\"i\":\"%s\",\"n\":\"%s\"}", \
                           rem, (rem>0 ? now+rem : 0), $2, $3, name }
            END{printf "]"}' "$LEASES")
    else
        s_leases="[]"
    fi

    # Storage: every real mount under /tmp/mnt plus /jffs
    s_disks=$(df -k 2>/dev/null | awk 'BEGIN{printf "["; n=0}
        $6 ~ /^\/tmp\/mnt\// || $6=="/jffs" {
            if(n++)printf ","
            printf "{\"m\":\"%s\",\"kb\":%.0f,\"u\":%.0f}", $6, $2, $3 }
        END{printf "]"}')

    grep -q " /tmp/opt " /proc/mounts 2>/dev/null && s_opt=1 || s_opt=0
}

# ---- first snapshot, so the first emitted sample already has real rates ----
set -- $(snap_cpu);  p_ct=$1; p_ci=$2
set -- $(snap_net);  p_wr=$1; p_wt=$2; p_lr=$3; p_lt=$4
set -- $(snap_sys);  p_cx=$1; p_ir=$2
set -- $(snap_fw);   p_ip=$1; p_ib=$2; p_fp=$3; p_fb=$4
slow_sample
tick=0

while :; do
    sleep "$INTERVAL"
    tick=$((tick + 1))
    if [ "$tick" -ge "$SLOWMOD" ]; then slow_sample; tick=0; fi

    set -- $(snap_cpu); c_ct=$1; c_ci=$2
    set -- $(snap_net); c_wr=$1; c_wt=$2; c_lr=$3; c_lt=$4
    set -- $(snap_sys); c_cx=$1; c_ir=$2; c_pr=$3
    set -- $(snap_fw);  c_ip=$1; c_ib=$2; c_fp=$3; c_fb=$4

    cpu_temp=$(awk -F: '/temperature/{gsub(/[^0-9]/,"",$2); print $2+0; exit}' "$THERMAL" 2>/dev/null)
    [ -z "$cpu_temp" ] && cpu_temp=0
    ct_now=$(cat "$CT_COUNT" 2>/dev/null); [ -z "$ct_now" ] && ct_now=0
    ct_max=$(cat "$CT_MAX" 2>/dev/null);   [ -z "$ct_max" ] && ct_max=0
    upsec=$(awk '{printf "%.0f", $1}' /proc/uptime)

    # Every delta and rate below is computed in awk. See the header.
    rates=$(awk -v i="$INTERVAL" \
        -v pct="$p_ct" -v pci="$p_ci" -v cct="$c_ct" -v cci="$c_ci" \
        -v pwr="$p_wr" -v pwt="$p_wt" -v plr="$p_lr" -v plt="$p_lt" \
        -v cwr="$c_wr" -v cwt="$c_wt" -v clr="$c_lr" -v clt="$c_lt" \
        -v pcx="$p_cx" -v pir="$p_ir" -v ccx="$c_cx" -v cir="$c_ir" '
        function pos(x) { return x < 0 ? 0 : x }
        BEGIN {
            dt = pos(cct - pct); di = pos(cci - pci)
            cpu = (dt > 0) ? (100.0 * (dt - di) / dt) : 0
            if (cpu < 0) cpu = 0; if (cpu > 100) cpu = 100
            printf "%.1f %.0f %.0f %.0f %.0f %.0f %.0f",
                   cpu,
                   pos(cwr - pwr) / i, pos(cwt - pwt) / i,
                   pos(clr - plr) / i, pos(clt - plt) / i,
                   pos(ccx - pcx) / i, pos(cir - pir) / i
        }')
    set -- $rates; r_cpu=$1; r_wr=$2; r_wt=$3; r_lr=$4; r_lt=$5; r_cx=$6; r_ir=$7

    fwd=$(awk -v pip="$p_ip" -v pib="$p_ib" -v pfp="$p_fp" -v pfb="$p_fb" \
              -v cip="$c_ip" -v cib="$c_ib" -v cfp="$c_fp" -v cfb="$c_fb" '
        function pos(x) { return x < 0 ? 0 : x }
        BEGIN { printf "%.0f %.0f %.0f %.0f", cip, cfp, pos(cip-pip), pos(cfp-pfp) }')
    set -- $fwd; f_inp=$1; f_fwp=$2; f_ind=$3; f_fwd=$4

    mem=$(awk '/^MemTotal/{t=$2} /^MemFree/{f=$2} /^Buffers/{b=$2} /^Cached:/{c=$2}
               END{printf "%.0f %.0f %.0f %.0f", t, f, b, c}' /proc/meminfo)
    set -- $mem; m_t=$1; m_f=$2; m_b=$3; m_c=$4
    load=$(awk '{printf "%s,%s,%s", $1, $2, $3}' /proc/loadavg)

    {
    printf '{'
    printf '"t":%s,"up":%s,' "$(date +%s)" "$upsec"
    printf '"host":{"model":"%s","name":"%s","fw":"%s","lan":"%s","mask":"%s"},' \
           "$h_model" "$h_name" "$h_fw" "$h_lan" "$h_mask"
    printf '"cpu":{"pct":%s,"temp":%s,"load":[%s],"ctxt":%s,"intr":%s,"prun":%s},' \
           "$r_cpu" "$cpu_temp" "$load" "$r_cx" "$r_ir" "${c_pr:-0}"
    printf '"mem":{"total":%s,"free":%s,"buffers":%s,"cached":%s},' \
           "$m_t" "$m_f" "$m_b" "$m_c"
    printf '"net":{"wan":{"if":"%s","rx":%s,"tx":%s},"lan":{"if":"%s","rx":%s,"tx":%s}},' \
           "$WANIF" "$r_wr" "$r_wt" "$LANIF" "$r_lr" "$r_lt"
    printf '"wifi":{"if":"%s","ssid":"%s","chan":%s,"temp":%s,"noise":%s,"rate":%s,"up":%s,"clients":%s},' \
           "$WLIF" "$(nvram get wl0_ssid | json_escape)" "$s_wchan" "$s_wtemp" \
           "$s_wnoise" "$s_wrate" "$s_wup" "$s_clients"
    printf '"ct":{"n":%s,"max":%s},' "$ct_now" "$ct_max"
    printf '"fw":{"inp":%s,"fwp":%s,"ind":%s,"fwd":%s},' "$f_inp" "$f_fwp" "$f_ind" "$f_fwd"
    printf '"dhcp":{"on":%s,"start":"%s","end":"%s","lease":%s,"leases":%s},' \
           "$d_on" "$d_st" "$d_en" "$d_ls" "$s_leases"
    printf '"disks":%s,"opt":%s' "$s_disks" "$s_opt"
    printf '}\n'
    } > "$TMP" 2>/dev/null

    # Atomic replace: a reader never sees a half-written file.
    mv "$TMP" "$JSON" 2>/dev/null

    p_ct=$c_ct; p_ci=$c_ci
    p_wr=$c_wr; p_wt=$c_wt; p_lr=$c_lr; p_lt=$c_lt
    p_cx=$c_cx; p_ir=$c_ir
    p_ip=$c_ip; p_ib=$c_ib; p_fp=$c_fp; p_fb=$c_fb
done
