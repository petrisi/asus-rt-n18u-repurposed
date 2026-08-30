# Long-term history with rrdtool

The dashboard shows a rolling few minutes held in the browser. This adds
persistent history — 24 hours at one-minute detail, 7 days at five, 30 days at
half-hourly — in about **1.1 MB that never grows**.

**This layer is optional and isolated.** It lives on the USB stick, and if the
stick or rrdtool is absent every part of it exits silently and the live
dashboard is unaffected. Keep it that way if you extend it.

## Pieces

    rrd_feeder.sh    samples once a minute into the RRDs
    rrd_ping.sh      latency probe, detached (see below)
    rrd_export.sh    RRD -> JSON for the browser

`portal_start.sh` calls all three from its supervision loop through
`run_gated()`, which paces each job with a stamp file *and* holds a lock
directory for the duration, so a slow run can never be launched twice.

## Install

    opkg install rrdtool          # 1.2.30 for armv7sf-k2.6
    cp portal/rrd_*.sh /jffs/portal/ && chmod 755 /jffs/portal/rrd_*.sh

Nothing else. The feeder creates the databases on first run.

## Why round-robin

Fixed size forever. Older data is consolidated rather than accumulated, so a
year costs the same as the first day. On a device with 128 MB of NAND and no
log rotation worth the name, that property matters more than the resolution it
gives up.

The five databases total 1.1 MB and will still total 1.1 MB next year.

## Schema decisions worth stealing

**Use `DERIVE`, not `COUNTER`, for byte and packet counters.** `COUNTER` treats
any decrease as a hardware counter wrap and synthesises an enormous rate. These
counters reset to zero on reboot, which `COUNTER` renders as a spike of about
10^10 bytes/second. `DERIVE` with `min=0` records the decrease as UNKNOWN,
which is the truth.

**Set the heartbeat to twice the step.** With a 60-second step and a
120-second heartbeat, one missed sample records UNKNOWN instead of carrying the
previous value forward. Gaps then appear as breaks in the line rather than as a
flat segment indistinguishable from a genuinely idle router.

**Age-check your input before trusting it.** A wedged collector leaves a
perfectly well-formed `status.json` that is simply old. The feeder checks its
mtime against `MAXAGE` and writes UNKNOWN rather than re-recording stale values
as current.

**Never do arithmetic on counters in the shell.** Raw values go to `rrdtool` as
strings and rrdtool does the maths in C. See the 2^31 truncation entry in
[99-gotchas.md](99-gotchas.md).

**Give negative-valued gauges a negative floor.** Wireless noise here sits
around −90 dBm; a `GAUGE` declared `0:U` discards every sample silently. The
`wifi.rrd` noise DS is declared `-120:0`, and `rrdtool lastupdate` confirming a
stored `-92` is the check that it works.

## Why the latency probe is a separate process

Three ICMP probes at up to two seconds each, plus a black-holed target that is
unbounded in practice even with `-W`, must never block a 60-second sampling
loop.

`rrd_ping.sh` runs detached and self-locking (an atomic `mkdir`, with a stale
lock broken only after 300 s), writing its result to `/tmp/portal/ping.kv`,
which the feeder reads on its *next* pass. Results are up to a minute old,
which is irrelevant for a trend line, and the feeder completes in well under a
second.

A probe that produces no output at all is recorded as 100% loss with unknown
latency — deliberately distinct from "no data", which is what an absent file
would mean.

## Exporting to the browser

Entware ships **rrdtool 1.2.30**, which predates JSON export, so
`rrd_export.sh` converts `rrdtool fetch` output with awk and writes static
files that lighttpd serves from tmpfs. Three non-obvious requirements:

**Place samples on a fixed time grid, indexed by timestamp.** `rrdtool fetch`
returns rows only from where each database actually starts, so a database
created ten minutes ago yields a handful of rows for a seven-day request while
an older one yields the full set. Appending in order produces series of
different lengths drawn against one shared x-axis — every young series
stretched across the whole chart, silently misaligned. Slot count is computed
from the *requested* window, never from the number of rows returned. The check
is that every series in one window has identical length:

    24h: 17 series, all length 1441
    7d:  17 series, all length 2017

**Never accumulate the payload in a shell variable.** busybox caps arguments to
its builtins at roughly 128 KB, and `[ -n "$big" ]` then fails with *Argument
list too long* and returns non-zero — which reads exactly like "empty". The
24h export alone is 122 KB, so this is not hypothetical. Fragments stream
through files and are tested with `[ -s file ]`, a size test rather than an
argument test.

**Delete the exported files when the source disappears.** If the stick is
pulled, stale JSON left in tmpfs renders as though it were current. Absent data
must look absent — `cleanup_exports()` removes all three windows, and the page
treats a 404 as "no history".

## Stagger the exports

A full export of all three windows is about **12 seconds of solid awk** on this
single core, which is a visible spike on the live dashboard every time it runs.
`rrd_export.sh` therefore takes an optional window argument, and the supervisor
paces them differently:

| window | export interval | cost |
|---|---|---|
| 24h | 5 min | ~3 s |
| 7d | 15 min | ~5 s |
| 30d | 60 min | ~4 s |

A 30-minute-resolution series does not change meaningfully between hourly
exports, so the coarse windows are cheap to neglect.

## Feeder cadence and the poll interval

The supervision loop polls every 30 s, and the feeder is gated at **55 s**, not
60. At 60 the gate would alternate between 60 s and 90 s actual cadence
depending on phase, and 90 s against a 120 s heartbeat leaves almost no margin
for a slow run before samples start recording as UNKNOWN.

## The clock

This router has no RTC. Until NTP syncs over the WAN it believes it is 2018,
and **rrdtool rejects updates older than the last one in the database** — a
multi-year jump mid-run will wedge the databases.

Confirm `date` is sane before starting the feeder for the first time. If you
have already polluted a database with a bad timestamp, deleting the `.rrd`
files and letting the feeder recreate them is the cheap fix.
