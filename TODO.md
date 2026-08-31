# Deferred and not yet done

## Deferred deliberately

Neither is urgent while the router is on an isolated bench segment, but both
must happen before it carries anything real.

- **Wi-Fi SSID and passphrase.** Currently whatever the QIS setup wizard was
  given during firmware setup. If that was a throwaway value typed only to get
  past the wizard, it is almost certainly weak and the SSID is not what you
  want long term. Change both, or disable the radio entirely
  (Wireless -> Professional -> Enable Radio: No) if this ends up wired-only.
  The radio is the one part of this box OpenWrt could never replace, so if you
  are not using it, turning it off costs nothing.

- **Admin password.** Still the value set during initial setup. The GUI is on
  the LAN only and SSH is now key-only, so this is not the weakest link, but it
  is still a shared secret in a wizard-shaped format.

Both are single GUI changes. They are listed here rather than done inline
because changing them mid-build means re-authenticating every tool that was
already working, for no gain while the box is on a bench.

## Not yet built

Ported from the sibling GT-AC5300 project, in rough dependency order.
The status dashboard (`docs/05-dashboard.md`) and the rrdtool history layer
(`docs/07-rrd-history.md`) are **done**. Remaining:

The BitTorrent seedbox is **done** — see `docs/06-bittorrent.md`. It runs on a
dedicated 128 GB volume (`BTDATA`), never on the boot stick.

Remaining there:

- **Move the data disk to the USB 3.0 port?** Both devices currently enumerate
  at 480 Mbps on the EHCI bus; the xHCI controller (5000 Mbps) has nothing
  attached. Moving it raises the ceiling — but USB 3.0 is a well-known 2.4 GHz
  interference source and 2.4 GHz is this router's **only** radio. Measure the
  Wi-Fi cost before taking the throughput.
- ~~**Upstream port forwarding.**~~ Resolved: since the router was moved it
  has a public WAN IP and is directly internet-facing. Verified from the
  internet side that tcp/51413 is reachable and everything else
  (22/23/80/443/8080/8200/9091/139/445) is filtered by the catch-all DROP, so
  inbound peers now connect directly with no upstream forwarding.

- **The credential work is now more urgent.** With a public WAN address the
  deferred items above (dashboard auth, Wi-Fi passphrase, admin password) are
  no longer protected by a second layer of NAT. Nothing is exposed to the WAN
  today, but the margin for a mistake is thinner.

## Open questions

- Whether `/etc/hosts` rewriting from the boot hook is ever needed. It is
  available (`/etc` is writable tmpfs, rewritten each boot) but so far there
  has been nothing to block — see the firmware update check in
  `docs/03-disable-telemetry.md`.
- Whether ASUS `httpd` itself can be stopped without losing the GUI as a
  recovery path. Not attempted.
