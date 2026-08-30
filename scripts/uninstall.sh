#!/bin/sh
#
# Removes everything this repository installs. Run ON the router.
#
# This cannot fail destructively: it only clears nvram values and deletes files
# under /jffs. The rootfs was never modified, so there is nothing to restore.

say() { echo "  $*"; }

echo
echo "=== 1. disabling the boot hook ==="
nvram set script_usbmount=""
say "script_usbmount cleared"

echo
echo "=== 2. restoring ASUS cloud defaults ==="
#
# Factory values on this model are aae_enable=2, aae_disable_force=0. Restoring
# them lets mastiff/aaews start again at the next boot.
nvram set aae_disable_force=0
nvram set aae_enable=2
nvram commit
say "aae_disable_force = $(nvram get aae_disable_force)"
say "aae_enable        = $(nvram get aae_enable)"

echo
echo "=== 3. removing scripts and logs ==="
for f in /jffs/usbmount.sh /jffs/services.sh /jffs/killsvc.sh \
         /jffs/services.log /jffs/killsvc.log; do
    [ -e "$f" ] && rm -f "$f" && say "removed $f"
done

echo
echo "=== done ==="
say "Left alone deliberately:"
say "  /jffs/.ssh/authorized_keys  - your key, remove by hand if you want it gone"
say "  Entware on the USB stick    - delete the entware/ directory to remove"
say "  telnetd_enable              - re-enable in the GUI if you need a way in"
say ""
say "The sshd account in /etc/passwd and the /opt bind mount live on tmpfs and"
say "disappear by themselves at the next reboot."
say ""
say "Reboot to return to stock behaviour."
echo
