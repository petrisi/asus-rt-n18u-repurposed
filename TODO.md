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

Ported from the sibling GT-AC5300 project, in rough dependency order:

- **Status dashboard.** Needs a port choice — ASUS `httpd` owns port 80 on the
  LAN address, so 8080 or similar.
- **Long-term metric history (rrdtool).** Available in Entware for this target.
  Note the clock: this router has no RTC, so the date is wrong until NTP syncs
  over the WAN. rrdtool rejects updates older than the last one, so a
  2018-to-now jump mid-run will corrupt a database. Do not start collecting
  before NTP has settled.
- **BitTorrent seedbox.** Possible, but this box has 256 MB of RAM against the
  GT-AC5300's 1 GB. Expect to tune Transmission's cache and peer limits down
  hard, and measure before trusting it.

## Open questions

- Whether `/etc/hosts` rewriting from the boot hook is ever needed. It is
  available (`/etc` is writable tmpfs, rewritten each boot) but so far there
  has been nothing to block — see the firmware update check in
  `docs/03-disable-telemetry.md`.
- Whether ASUS `httpd` itself can be stopped without losing the GUI as a
  recovery path. Not attempted.
