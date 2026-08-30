#!/bin/sh
# nvram script_usbmount points here. Fires on EVERY USB mount event, including
# the boot-time mount of an already-inserted stick (verified: ~25-40s uptime on
# a cold boot) and every later insertion or removal.
#
# Because it fires on every event, each stage below holds its own
# single-instance lock -- without one, plugging in a second disk starts a rival
# copy. Every stage is also [ -x ] guarded, so deleting any one file disables
# just that stage. The recovery path is rm, never firmware restore: this
# model's rootfs is squashfs and is never touched by any of this.

[ -x /jffs/services.sh ]     && /jffs/services.sh &      # /opt, sshd account, sshd, data mount
[ -x /jffs/killsvc.sh ]      && /jffs/killsvc.sh &       # telemetry sweep
[ -x /jffs/transmission.sh ] && /jffs/transmission.sh &  # optional seedbox

# Delayed: rc is still building its firewall chains for the first minute, and
# portal_start.sh installs iptables rules of its own. Its supervision loop
# re-applies them every 30s regardless, so this delay is politeness, not a
# dependency.
[ -x /jffs/portal/portal_start.sh ] && ( sleep 55; /jffs/portal/portal_start.sh ) >/dev/null 2>&1 &

exit 0
