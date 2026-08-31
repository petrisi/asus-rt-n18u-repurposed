# The status dashboard

A single-page status portal: CPU load and temperature, memory, connection
counts, WAN/LAN throughput graphs, firewall drops, wireless detail, DHCP
leases and storage.

`scripts/portal/www/index.html` is the whole front end — one file, no
frameworks, no external requests. That is not minimalism for its own sake: this
router has no reason to reach the internet, and a dashboard that needs a CDN
stops working exactly when you most want to look at it.

## The architecture

Three processes, deliberately decoupled:

    portal_collector.sh   samples every 2s  ->  /tmp/portal/status.json
    lighttpd              serves the page and that JSON
    portal_start.sh       supervises both, re-applies firewall rules

**At runtime the dashboard needs neither Entware nor the USB stick.** It uses
the firmware's own `/usr/sbin/lighttpd` and writes only to tmpfs. Pull the
stick and the dashboard keeps working.

**At startup it does need the stick**, because `script_usbmount` is the only
boot hook this model has (see [02-persistence.md](02-persistence.md)). That is
a property of the platform rather than a design choice, and it is the one place
where the RT-N18U is weaker than the GT-AC5300, which can hook `rc` directly.

Everything is in tmpfs, so sampling never touches flash. At a 2 s interval this
would otherwise be about 43,000 writes a day onto NAND.

## Install

    mkdir -p /jffs/portal/www
    cp portal/*.sh /jffs/portal/
    cp portal/www/index.html /jffs/portal/www/
    chmod 755 /jffs/portal/*.sh

`usbmount.sh` starts it 55 seconds after the hook fires — late enough that `rc`
has finished building its firewall chains, so the rules `portal_start.sh` adds
are not immediately overwritten. The supervision loop re-applies them every
30 s regardless, so the delay is politeness rather than a dependency.

Then browse to `http://192.168.1.1:8080/`.

**The first sample takes about 5 seconds.** The collector runs its `wl`
slow-sample and then waits one interval before writing, so that the first
emitted rates are real deltas rather than fabricated zeroes. During that window
`/status.json` 404s and the page shows placeholders. This is expected once per
boot; it is not a fault.

## Platform differences from the GT-AC5300 version

Four things needed changing, all verified on the device:

**lighttpd's module directory is `/usr/lib`, not `/usr/lib/lighttpd`.** The
binary looks in the latter by default and finds nothing. The generated config
sets `server.modules-dir = "/usr/lib"`. `mod_alias`, `mod_auth` and
`mod_access` are all present as `.so` files there.

**`mod_indexfile` and `mod_staticfile` are compiled into this build.** Listing
them in `server.modules` produces:

    (plugin.c.183) Cannot load plugin mod_indexfile more than once

which is a warning today and an error in later lighttpd releases. Load only
`mod_access`, `mod_alias` and `mod_auth`.

**There is no `timeout` applet in this busybox.** The bounded `wl` helper polls
a backgrounded call with `usleep` and sends `SIGKILL` at 5 s instead. `usleep`
does exist here.

**Temperature comes from `/proc/dmu/temperature`.** There is no
`/sys/class/thermal` on this platform at all. The format is
`CPU temperature\t: 66'C`, so it needs parsing rather than a straight read. The
radio has its own sensor via `wl -i eth1 phy_tempsense`, reported separately.

The page is also shaped for this hardware rather than the GT-AC5300's: one CPU
core, one 2.4 GHz radio, four LAN ports.

## Protecting it, and exposing it safely

**Layout:** plain HTTP on `8080` bound to the LAN address only; **HTTPS on
`8443` bound to `0.0.0.0`** and accepted from the WAN. Digest auth is global, so
both sockets — and every JSON endpoint behind them — require credentials.

    LAN   http://192.168.1.1:8080/     digest auth
    LAN   https://192.168.1.1:8443/    digest auth
    WAN   https://<public-ip>:8443/    digest auth      <- the only WAN path
    WAN   http  :8080                  DROPped

### Why TLS and not just digest auth

Digest auth protects the *password* — it is never sent in the clear. It does
nothing for the *payload*. Over plain HTTP to the internet, every sample the
dashboard serves (WAN address, traffic rates, DHCP leases with hostnames and
MACs, uptime, temperatures) is readable by anyone on the path. That is a
worthwhile amount of information about a home network to hand out.

lighttpd 1.4.39 on this firmware has SSL compiled in, and `/usr/sbin/openssl`
exists, so TLS costs nothing but a self-signed certificate:

    openssl req -new -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/CN=RT-N18U/O=rtn18u-portal" -keyout k.pem -out c.pem
    cat k.pem c.pem > /jffs/portal/portal.pem && chmod 600 /jffs/portal/portal.pem

Browsers will warn once. **Check the fingerprint rather than clicking through**
— that is the only thing standing in for a CA here:

    openssl x509 -in /jffs/portal/portal.pem -noout -fingerprint -sha256

### The firewall rule is conditional on the password existing

`ensure_fw()` only inserts the WAN ACCEPT for 8443 when **both** the
certificate and `.htdigest` are present, and actively deletes it otherwise. An
exposed dashboard with no password is a far worse failure than an unreachable
one, so the rule is tied to the thing that protects it rather than being set
once and trusted.

### Credentials

`/jffs/portal/.htdigest`, mode 600, outside the document root, and
`url.access-deny` refuses it explicitly (verified: 403). The format is
`user:realm:MD5(user:realm:password)` and the realm must match `REALM` in
`portal_start.sh` — a digest hash is computed over the realm, so a mismatch
makes every login fail silently.

    printf 'admin:rtn18u:%s' "$PASSWORD" | md5sum   # -> the hash field

### Verify from outside, not from the rule listing

    curl -sk -o /dev/null -w '%{http_code}\n' https://<public-ip>:8443/          # 401
    curl -sk --digest -u admin:<pw> -o /dev/null -w '%{http_code}\n' \
         https://<public-ip>:8443/                                              # 200
    curl -s  -o /dev/null -w '%{http_code}\n' http://<public-ip>:8080/          # filtered

### Residual risk, stated plainly

This publishes a **2016 web server on an EOL firmware that will never be
patched** to the whole internet. TLS and a strong password address
eavesdropping and guessing; they do nothing about a flaw in lighttpd itself.
If you do not need remote access continuously, an SSH tunnel gives the same
result with no listener exposed:

    ssh -L 8080:192.168.1.1:8080 admin@<router>

Consider also restricting the ACCEPT rule to known source addresses, and note
that port 8443 will attract background scanning within hours.

## Older notes on protecting it

`portal_start.sh` binds lighttpd to the LAN address (`server.bind`) rather than
`0.0.0.0`, so the WAN interface is not listening in the first place. The
iptables and ip6tables DROP rules on the WAN interface are belt-and-braces —
and note that `ip6tables` is a separate table, so opening or closing a port in
`iptables` does nothing for IPv6.

Authentication is **off by default** and the log says so plainly at every
start:

    NOTE: /jffs/portal/.htdigest absent -- dashboard is unauthenticated on the LAN

To enable it, create `/jffs/portal/.htdigest` containing standard
`user:realm:md5hash` lines. The realm must match `REALM` in `portal_start.sh`
(`rtn18u`) — a digest hash is computed over the realm, so a mismatch means
every login silently fails.

**Digest, not basic.** This is plain HTTP; basic auth would put the password on
the wire with every single request.

The file lives outside the document root on purpose. `url.access-deny` also
refuses `.htdigest` explicitly, which closes the class of mistake rather than
the single instance — verified:

    $ curl -o /dev/null -w '%{http_code}' http://192.168.1.1:8080/.htdigest
    403

## Two things worth keeping

**Judge liveness by data freshness, not just process existence.** A hung
collector stays in the process table indefinitely and keeps serving a perfectly
valid, perfectly frozen `status.json`. The page compares the sample timestamp
against the browser clock and shows a **data stale** badge rather than a chart
that looks live.

The supervisor watches *both* signals, because they catch different failures:

| signal | failure it catches | detection time |
|---|---|---|
| collector pid absent | the collector **died** | one poll, ~30 s |
| `status.json` age > `STALE` | the collector **hung** | ~150-180 s |

Freshness alone would leave a dead collector unnoticed for up to `STALE`
seconds; process-existence alone is the mistake that left the sibling project
with three days of frozen graphs. Both are cheap, so check both. Verified by
`kill -9` (restarted in 31 s) and by `kill -STOP`, which leaves the process in
the table while it stops writing — the exact shape of the original outage.

**Bound everything that reads `/proc` or calls `wl`.** `wl` ioctls can block
indefinitely against this driver. A blocked collector does not crash — it
freezes every number on the page at once, which is a much harder failure to
notice than a missing one.

## All counter arithmetic happens in awk

This is the trap most likely to bite anyone extending the collector. busybox
`ash` silently truncates arithmetic at 2^31:

    # rx=18821963980 ; echo $((rx + 1))
    1

Interface byte counters pass that within hours of real traffic, so a
shell-computed delta yields a permanent `0` for the busier direction while the
quieter one still looks right — which reads as swapped labels, not as a bug.
`awk` uses doubles and is exact to 2^53. Every delta and rate in
`portal_collector.sh` is computed there, and the header says so in capitals.
