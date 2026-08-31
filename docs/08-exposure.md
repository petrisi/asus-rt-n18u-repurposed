# If it faces the internet

Since 2026-08-31 this router holds a **public WAN address** and is no longer
behind another NAT. The firmware will never be patched again, so treat the box
as untrusted infrastructure.

## Verified state

Probed from the internet side — not from the LAN, and not by reading the config:

| port | result |
|---|---|
| **tcp/51413** | **OPEN** — BitTorrent peer port, intended |
| tcp/22, 23, 80, 443, 8080, 8200, 9091, 139, 445 | filtered |

Do this yourself rather than trusting a rule listing. From a host that reaches
the internet independently of the router (a laptop on another network, a phone
on mobile data):

    for p in 22 23 80 443 8080 8200 9091 51413 445 139; do
      timeout 6 bash -c "echo > /dev/tcp/<public-ip>/$p" 2>/dev/null \
        && echo "tcp/$p OPEN" || echo "tcp/$p filtered"
    done

## How the firewall actually works here

The INPUT chain reads alarmingly at first glance:

    Chain INPUT (policy ACCEPT)

but ends with a catch-all:

    DROP  all  --  *  *  0.0.0.0/0  0.0.0.0/0

So the effective posture is deny-by-default. New inbound connections on `eth0`
that are not explicitly accepted fall through to that final rule. ASUS's
`PTCSRVWAN` chain is empty on this unit, and remote admin is off
(`misc_http_x=0`).

**Consequence worth internalising: one deleted or misordered rule removes the
only thing between a dozen services and the internet.** Insert with
`-I INPUT 1`, never `-A` — an appended rule lands *below* the trailing DROP and
never matches, which looks exactly like the rule not working, because it is not.

## A lot binds promiscuously

These listen on `0.0.0.0`, i.e. on the WAN interface too, and are reachable
only because the catch-all DROP stops them:

    tcp  8200          minidlna (media server)
    tcp  18017, 60029  ASUS services
    udp  137, 138      NetBIOS (samba)
    udp  1900          SSDP / UPnP
    udp  5353, 5355    mDNS, LLMNR
    udp  18018, 37000, 38000, 42000, 43000, 59000, 60566   ASUS services
    udp  67            DHCP server

Only SSH (`192.168.1.1:22`), the dashboard (`192.168.1.1:8080`) and the
Transmission RPC (`127.0.0.1:9091`) are bound narrowly on purpose.

Binding narrowly is far stronger than filtering broadly. Where a service offers
a bind address, use it — that is why `sshd_config` sets `ListenAddress` and why
the dashboard's lighttpd sets `server.bind` rather than relying on its iptables
rule alone.

### Closed on 2026-08-31

All three now disabled by their proper nvram toggles rather than kill loops:

    nvram set dms_enable=0        # minidlna, tcp/8200
    nvram set upnp_enable=0       # miniupnpd
    nvram set enable_samba=0      # smbd/nmbd, 137/138/139/445
    nvram set daapd_enable=0
    nvram commit
    service stop_dms; service stop_upnp; service stop_samba

Ports 8200, 137, 138, 139 and 445 all went quiet and stayed quiet across a
reboot. Disabling UPnP does **not** affect the seedbox: Transmission has
`port-forwarding-enabled: false` and uses the static iptables rules from
[06-bittorrent.md](06-bittorrent.md) instead.

### udp/1900 is WPS, not UPnP

Stopping `miniupnpd` left udp/1900 still listening. Tracing the socket inode
through `/proc/net/udp` to `/proc/<pid>/fd` identified the owner:

    inode 852 -> pid 183 : /bin/wps_monitor

`wps_monitor` implements WPS's UPnP external-registrar, which is a different
thing from the IGD daemon and binds the same SSDP port. **Setting
`wps_enable=0` does not stop it** — verified: it came straight back after
`service restart_wireless`. Another instance of a setting whose presentation
layer exists without the code behind it.

Killing it works and it does not respawn, so `wps_monitor` is in `TARGETS` in
`scripts/killsvc.sh`. The radio keeps beaconing (`wl bss` = up, `wl isup` = 1)
with `eapd`, `nas` and `wlceventd` untouched.

**Caveat worth knowing:** that was verified with **zero clients associated**, so
while the radio is demonstrably up, client authentication was not exercised. If
you use the Wi-Fi, connect something and confirm before trusting it. WPS is
disabled either way, which on an internet-facing router is a gain in itself.

### Still broadly bound

    tcp  18017, 3394, 5473      ASUS services
    udp  18018, 5353 (mDNS/avahi), 5355 (LLMNR), 5474
    udp  37000, 38000, 42000, 43000, 59000, 60566   ASUS services
    udp  67                     DHCP server

None reachable from the WAN — the catch-all DROP covers them — but they remain
one rule away. `avahi-daemon` (5353) is the obvious next candidate if you do
not need mDNS service discovery on the LAN.

## IPv6

Currently **disabled** (`ipv6_service=disabled`, no global address). That
removes an entire surface.

If you ever enable it, remember `iptables` and `ip6tables` are **independent
tables** and every rule needs writing twice. The scripts here already maintain
both — `transmission.sh` opens 51413 in each, and `portal_start.sh` drops 8080
in each. A service reachable over v6 while you believe you closed it over v4 is
a quiet and common failure.

## Rules do not survive on their own

`rc` rebuilds the firewall chains on various events, discarding anything added
by hand. `ensure_fw()` in `portal_start.sh` and `transmission.sh` reasserts the
rules every supervision pass, deleting before inserting so repeats cannot stack
duplicates.

## SSH will be scanned continuously

On a public address you will see a steady stream of probes. Ours is not exposed
to the WAN at all (`ListenAddress 192.168.1.1`), which is the strongest form of
this mitigation. If you ever do expose it:

- keep `PasswordAuthentication no` — already set
- move it off port 22, which removes nearly all automated noise
- restrict the source address if your situation allows

## Devices behind it inherit its trust level

Clients using this box as gateway and DNS are trusting an unpatched,
internet-facing device. That is a decision worth making deliberately. If you
run an SSID on it, consider client isolation:

    nvram get wl0_ap_isolate     # 0 = clients can reach each other

The Wi-Fi passphrase matters more here than it did behind a second NAT — see
`TODO.md`.

## What to check periodically

    iptables -L INPUT -n -v | tail -3        # catch-all DROP still last
    nvram get misc_http_x                    # still 0
    netstat -tuln | grep -v '127.0.0.1\|192.168.1.1'   # what binds broadly
    cat /jffs/killsvc.log                    # daemons stayed dead
    ip6tables -L INPUT -n -v | head          # if v6 ever gets enabled

And re-run the external probe after any firmware or configuration change. The
listing is what you intended; the probe is what is true.
