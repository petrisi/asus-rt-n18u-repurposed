#!/bin/sh
# nvram script_usbmount points here. Fires on every USB mount event, including
# the boot-time mount of an already-inserted stick (verified: fires at ~25s
# uptime on a cold boot).
#
# Every stage is backgrounded so rc's mount handler is never blocked, and every
# stage is [ -x ] guarded so deleting any one file disables just that stage.
# The recovery path is rm, never firmware restore -- this model's rootfs is
# squashfs and is never touched by any of this.

[ -x /jffs/services.sh ] && /jffs/services.sh &
[ -x /jffs/killsvc.sh ]  && /jffs/killsvc.sh &

# Delayed: rc is still building its firewall chains for the first minute, and
# portal_start.sh installs iptables rules of its own. Its supervision loop
# re-applies them every 30s regardless, so this delay is politeness, not a
# dependency.
[ -x /jffs/portal/portal_start.sh ] && ( sleep 55; /jffs/portal/portal_start.sh ) >/dev/null 2>&1 &

exit 0
