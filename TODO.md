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

- **BitTorrent seedbox — viable, on a dedicated disk.** Originally declined
  because the only storage was the boot stick, and `script_usbmount` makes that
  stick the ignition key for SSH, the sweep, the dashboard and the RRDs.

  A separate 128 GB volume removes that objection entirely. Formatted ext4,
  labelled `BTDATA`, mounted at `/tmp/mnt/BTDATA`, 117.4 GB usable:

  | | measured |
  |---|---|
  | sequential read | 28.4 MB/s (228 Mbps) |
  | random read, 48 distinct 4 MB chunks, cold cache | 38.4 MB/s (307 Mbps) |
  | sequential write | 21.3 MB/s (171 Mbps) |
  | CPU idle | 86% |
  | hash throughput | ~21 MB/s |

  Seeding is read-dominated, and 28-38 MB/s of read is far beyond any domestic
  upload link. This is not the bottleneck.

  Still to decide before installing anything:
  - Both USB devices enumerate at **480 Mbps on the EHCI bus**; the xHCI
    controller (5000 Mbps) has nothing attached. Moving the data disk to the
    USB 3.0 port would raise the ceiling — but USB 3.0 is a well-known 2.4 GHz
    interference source, and 2.4 GHz is this router's **only** radio. Measure
    the Wi-Fi cost before taking the throughput.
  - `BTDATA` must be mounted at boot. The firmware should automount it by label
    now that it has a recognised filesystem; verify on the next reboot rather
    than assuming.
  - RAM is 256 MB total. Transmission's cache and peer limits need tuning down.

## Open questions

- Whether `/etc/hosts` rewriting from the boot hook is ever needed. It is
  available (`/etc` is writable tmpfs, rewritten each boot) but so far there
  has been nothing to block — see the firmware update check in
  `docs/03-disable-telemetry.md`.
- Whether ASUS `httpd` itself can be stopped without losing the GUI as a
  recovery path. Not attempted.
