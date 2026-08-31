# Deferred and not yet done

## Deferred deliberately

Neither is urgent while the router is on an isolated bench segment, but both
must happen before it carries anything real.

- ~~**Wi-Fi SSID and passphrase.**~~ Done 2026-08-31. SSID kept, passphrase
  replaced with a strong one.

- ~~**Admin password.**~~ Done 2026-08-31, and verified end to end over both
  the web API and telnet. See the note below — the obvious way to change it
  does not work.

- **Dashboard authentication.** Still open: the portal runs unauthenticated on
  the LAN and logs a NOTE saying so at every start. Create
  `/jffs/portal/.htdigest` with realm `rtn18u` to enable it
  (`docs/05-dashboard.md`).

  Consider also whether the radio is wanted at all. No client has ever
  associated; if the box is wired-only, disabling the radio
  (Wireless -> Professional -> Enable Radio: No) closes more surface than any
  passphrase, and makes the `wps_monitor`/udp-1900 question moot.

## Changing the admin password: nvram alone does not work

Recorded because it cost a debugging cycle. There are **three** places the
credential lives:

| store | used by | set how |
|---|---|---|
| `acc_list` (hashed) | ASUS `httpd` / web GUI | derived by httpd |
| `/etc/shadow` (MD5-crypt) | telnet, `login` | regenerated at boot |
| `http_passwd` | staging value only | what you post |

`nvram set http_passwd=<plaintext>; nvram commit; service restart_httpd`
appears to succeed and changes nothing — the old password keeps working,
because httpd validates against `acc_list` and never re-derives it.

The change must go through the GUI's own mechanism, which is what regenerates
all three:

    POST /start_apply.htm
      action_mode=apply
      action_script=restart_httpd
      http_username=admin
      http_passwd=<plaintext>
      current_page=Advanced_System_Content.asp

Verify by logging in with the new password *and* confirming the old one is
refused — on both the web API and telnet, since they consult different stores.

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
