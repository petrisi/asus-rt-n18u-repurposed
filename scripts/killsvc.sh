#!/bin/sh
# Kill ASUS daemons that have no nvram switch, on RT-N18U stock firmware.
# Invoked at boot/hotplug from /jffs/usbmount.sh (nvram script_usbmount).
#
# TO DISABLE THE WHOLE MECHANISM: delete this file. The caller is [ -x ]
# guarded, so a missing file is a silent no-op. No reboot, no rootfs changes.
#
# Differences from the GT-AC5300 original, all verified on this device:
#   - ahs/asd/conn_diag/nt_*/vis-*/netool/usbmuxd do not exist on this
#     firmware branch. It predates the Trend Micro stack, so there is no
#     respawn watchdog and no_asd=1 is unnecessary.
#   - mastiff is the ASUS cloud/call-home daemon on this model. It RESPAWNS
#     (watchdog is a symlink to /sbin/rc). Killing it here only sticks because
#     nvram aae_disable_force=1 + aae_enable=0 are set -- see install notes.
#     Both halves are required, exactly as no_asd=1 was on the GT-AC5300.
#   - eapd AND nas are both wireless authentication here. Killing either
#     breaks WPA client auth. Neither is in TARGETS, deliberately.
#   - disk_monitor is NOT killed: USB storage carries the boot hook itself.
#   - miniupnpd is NOT killed: it has a working GUI toggle (WAN -> UPnP),
#     which is a cleaner off switch than a kill loop.

LOG=/jffs/killsvc.log
LOCK=/tmp/killsvc.lock

TARGETS="mastiff infosvr lld2d wpsaide u2ec lpd"

# Once per boot. /tmp is tmpfs, so the lock clears itself.
[ -f "$LOCK" ] && exit 0
touch "$LOCK"

# keep the log bounded -- /jffs is NAND we do not want to churn
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
    rm -f "$LOG"
fi

echo "=== run start, uptime $(cut -d' ' -f1 /proc/uptime) ===" >> "$LOG"

# Services come up staggered over the first minutes of boot, so sweep
# repeatedly rather than once.
i=0
while [ "$i" -lt 6 ]; do
    sleep 30
    for p in $TARGETS; do
        killall "$p" 2>/dev/null
    done
    i=$((i + 1))
done

echo "--- final state, uptime $(cut -d' ' -f1 /proc/uptime) ---" >> "$LOG"
for p in $TARGETS; do
    if pidof "$p" >/dev/null 2>&1; then
        echo "  $p: RUNNING" >> "$LOG"
    else
        echo "  $p: gone" >> "$LOG"
    fi
done
echo >> "$LOG"

exit 0
