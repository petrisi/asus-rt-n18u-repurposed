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

- **BitTorrent seedbox — decided against.** Not on performance grounds; the
  box measures better than expected:

  | | measured on this unit |
  |---|---|
  | CPU idle | 86% (the ~1.0 load average is I/O wait, not CPU) |
  | hash throughput | ~21 MB/s (md5 proxy — no `sha1sum` in this busybox) |
  | RAM free | ~200 MB |
  | USB write | 9.1 MB/s / 73 Mbps |

  That would run a modest seedbox. The objection is architectural and specific
  to this model: **the USB stick is the boot hook.** `script_usbmount` is the
  only hook available, so the same stick carries the ignition for SSH, the
  telemetry sweep, the dashboard, the RRD databases and the sshd host keys.
  Sustained torrent writes there mean flash wear on the one device everything
  depends on, I/O contention on the path that is already the bottleneck, and a
  filesystem corruption that takes down remote access rather than just
  downloads.

  On the GT-AC5300 the stick is only storage and the same mistake costs you
  Entware alone. Here it costs the whole stack.

  If it is ever wanted: use a **separate disk on the front USB 3.0 port** and
  leave the boot stick untouched. That removes every objection except the
  9.1 MB/s figure, which is a property of this particular stick on a USB 2.0
  port rather than of the platform.

## Also worth doing

- **Enable dashboard authentication.** It currently runs unauthenticated on the
  LAN; `portal_start.sh` logs a NOTE saying so at every start. Create
  `/jffs/portal/.htdigest` with realm `rtn18u` to turn it on.

## Open questions

- Whether `/etc/hosts` rewriting from the boot hook is ever needed. It is
  available (`/etc` is writable tmpfs, rewritten each boot) but so far there
  has been nothing to block — see the firmware update check in
  `docs/03-disable-telemetry.md`.
- Whether ASUS `httpd` itself can be stopped without losing the GUI as a
  recovery path. Not attempted.
