#!/bin/sh
# nvram script_usbmount points here. Fires on every USB mount event, including
# the boot-time mount of an already-inserted stick (verified: fires at ~25s
# uptime on a cold boot).
#
# Both stages are backgrounded so rc's mount handler is never blocked, and both
# are [ -x ] guarded so deleting either file disables that stage cleanly.
# The recovery path is rm, never firmware restore -- this model's rootfs is
# squashfs and is never touched by any of this.

[ -x /jffs/services.sh ] && /jffs/services.sh &
[ -x /jffs/killsvc.sh ]  && /jffs/killsvc.sh &

exit 0
