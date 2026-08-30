#!/bin/sh
#
# Guided installer. Run this ON the router, from the scripts/ directory.
#
# Unlike the GT-AC5300 sibling, there is no dangerous step for this script to
# refuse. Nothing here writes outside /jffs and nvram; the rootfs is squashfs
# and is never touched. The uninstall path is scripts/uninstall.sh, or rm.

USB_LABEL=ROUTERDATA

say()  { echo "  $*"; }
warn() { echo "  WARNING: $*"; }
fail() { echo "  ERROR: $*"; exit 1; }

echo
echo "=== 1. platform checks ==="

[ -d /jffs ] || fail "/jffs not present - is this an Asuswrt router?"
touch /jffs/.wtest 2>/dev/null || fail "/jffs is not writable"
rm -f /jffs/.wtest
say "/jffs writable: yes"

_model=$(nvram get productid 2>/dev/null)
say "model:    $_model"
say "firmware: $(nvram get buildno 2>/dev/null).$(nvram get extendno 2>/dev/null)"
say "kernel:   $(uname -r) $(uname -m)"
[ "$_model" = "RT-N18U" ] || warn "this repository was written for RT-N18U, not $_model.
           Re-verify every assumption in docs/ before continuing."

_rootfs=$(awk '$2=="/" && $3!="rootfs" {print $3}' /proc/mounts | head -1)
say "rootfs:   $_rootfs (expected squashfs - read-only by construction)"

echo
echo "=== 2. USB volume ==="
#
# The hook only fires on USB mount, so without a labelled, mounted volume
# nothing in this repository will ever run.
_dev=$(blkid 2>/dev/null | grep "LABEL=\"$USB_LABEL\"" | cut -d: -f1)
[ -n "$_dev" ] || fail "no volume with LABEL=$USB_LABEL found.
         See docs/04-usb-and-entware.md - and note the relabelling trap
         in docs/99-gotchas.md before running tune2fs."
_mp=$(awk -v d="$_dev" '$1==d {print $2; exit}' /proc/mounts)
[ -n "$_mp" ] || fail "$_dev (LABEL=$USB_LABEL) exists but is not mounted"
say "volume $USB_LABEL: $_dev at $_mp"

if [ -x /opt/bin/opkg ] || [ -d "$_mp/entware" ]; then
    say "entware: present"
else
    warn "Entware not found at $_mp/entware.
           SSH comes from Entware on this model - see docs/04-usb-and-entware.md.
           killsvc.sh will still work without it."
fi

echo
echo "=== 3. installing scripts to /jffs (safe, reversible) ==="
for f in usbmount.sh services.sh killsvc.sh; do
    [ -f "$f" ] || fail "$f not found - run this from the scripts/ directory"
    cp "$f" "/jffs/$f" && chmod 755 "/jffs/$f"
    say "installed /jffs/$f"
done

if [ -d portal ]; then
    mkdir -p /jffs/portal/www
    for f in portal/*.sh; do
        [ -f "$f" ] || continue
        cp "$f" "/jffs/portal/" && chmod 755 "/jffs/portal/$(basename "$f")"
        say "installed /jffs/portal/$(basename "$f")"
    done
    if [ -f portal/www/index.html ]; then
        cp portal/www/index.html /jffs/portal/www/
        say "installed /jffs/portal/www/index.html"
    fi
    [ -s /jffs/portal/.htdigest ] || \
        warn "dashboard will run UNAUTHENTICATED on the LAN.
           Create /jffs/portal/.htdigest (realm rtn18u) to require a login -
           see docs/05-dashboard.md."
fi

echo
echo "=== 4. syntax-checking everything installed ==="
_bad=0
for f in /jffs/usbmount.sh /jffs/services.sh /jffs/killsvc.sh /jffs/portal/*.sh; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then say "OK   $f"; else say "FAIL $f"; _bad=1; fi
done
[ "$_bad" -eq 0 ] || fail "syntax errors above - nvram not touched"

echo
echo "=== 5. nvram ==="
#
# aae_disable_force stops mastiff respawning; the kill alone does not, and the
# flag alone does not stop a running instance. Both halves are required.
say "setting aae_disable_force=1 / aae_enable=0 (stops the mastiff respawn)"
nvram set aae_disable_force=1
nvram set aae_enable=0
say "setting script_usbmount=/jffs/usbmount.sh (the boot hook)"
nvram set script_usbmount=/jffs/usbmount.sh
nvram commit
say "aae_disable_force = $(nvram get aae_disable_force)"
say "aae_enable        = $(nvram get aae_enable)"
say "script_usbmount   = $(nvram get script_usbmount)"

echo
echo "=== 6. stop what is already running ==="
service stop_mastiff >/dev/null 2>&1
say "requested stop_mastiff (the flag above prevents the restart)"

echo
echo "=== done ==="
say "Nothing has been written outside /jffs and nvram."
say ""
say "Reboot, then check:"
say "    cat /jffs/services.log      # /opt bind mount and sshd startup"
say "    cat /jffs/killsvc.log       # per-process final state"
say "    cat /tmp/portal/portal.log  # dashboard startup"
say "    http://$(nvram get lan_ipaddr 2>/dev/null):8080/   # the dashboard"
say "    pidof eapd nas              # both MUST still be running"
say ""
say "Do not disable telnet until an SSH key login has survived a reboot."
echo
