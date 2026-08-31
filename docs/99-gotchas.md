# Platform traps

Read this before debugging anything. Every entry cost real time on this
hardware.

## Do not carry findings across models

The single most expensive assumption available. The sibling GT-AC5300 project
concludes that `script_usbmount` is a decoy. **On the RT-N18U it is the only
working boot hook.** Conversely, that project's binary-wrapping persistence is
impossible here.

Same vendor, same OS, opposite answers. Verify per device:

    strings /sbin/rc | grep -n -B8 -A8 <thing you are assuming>

## wps_enable=0 does not stop wps_monitor

A specific and useful case of the entry below. `wps_monitor` binds **udp/1900**
— WPS's UPnP external-registrar, unrelated to `miniupnpd` — so stopping UPnP
leaves the SSDP port open. Setting `wps_enable=0` and running
`service restart_wireless` brings the daemon straight back.

`killall wps_monitor` works and it does not respawn. Verified that the radio
keeps beaconing afterwards (`wl bss` up, `wl isup` 1) with `eapd`, `nas` and
`wlceventd` unaffected — though with no clients associated, client
authentication itself was not exercised.

To find out what actually holds a port when `netstat -p` is unavailable
(busybox has no `-p`), match the socket inode by hand:

    awk 'NR>1 {split($2,a,":"); if (a[2]=="076C") print $10}' /proc/net/udp
    # then grep that inode in /proc/*/fd

## The admin password lives in three places; nvram alone changes none of them

`nvram set http_passwd=<plaintext>` is accepted, survives `nvram commit`, and
does nothing: `httpd` validates against the hashed `acc_list`, and telnet
against `/etc/shadow`. Both are derived only when the change goes through the
GUI form. Post it to `start_apply.htm` with `action_script=restart_httpd`
instead, then verify against **both** the web API and telnet — they consult
different stores, so testing one proves nothing about the other.

| store | used by | set how |
|---|---|---|
| `acc_list` (hashed) | ASUS `httpd` / web GUI | derived by httpd |
| `/etc/shadow` (MD5-crypt) | telnet, `login` | regenerated at boot |
| `http_passwd` | staging value only | what you post |

The change has to go through the GUI's own mechanism, which is what regenerates
all three:

    POST /start_apply.htm
      action_mode=apply
      action_script=restart_httpd
      http_username=admin
      http_passwd=<plaintext>
      current_page=Advanced_System_Content.asp

Verify by logging in with the new password *and* confirming the old one is
refused, on both paths.

## nvram accepts settings for features the firmware does not have

Writing `sshd_enable` and `sshd_authkeys` on stock RT-N18U appears to succeed
and does nothing — `httpd` discards nvram for features absent from
`rc_support`. Nothing errors. Check `nvram get` afterwards, and check
`rc_support`:

    nvram get rc_support | tr ' ' '\n' | grep -i <feature>

A GUI field or an accepted nvram write is not evidence that a feature exists.

## `/etc` is regenerated during boot

`/etc` is a symlink to `/tmp/etc` (tmpfs), and `rc` rewrites it while booting.
Anything a boot hook writes there early is destroyed without warning.

Observed: the hook fired at 25 s uptime and appended the `sshd` account to
`/etc/passwd` at 19:22:59; `sshd -t` failed one second later with *"Privilege
separation user sshd does not exist"*, and `/tmp/etc/passwd` had an mtime of
19:23 containing only `admin`, `nas`, `nobody`.

**Write to `/etc` with add-verify-retry, never add-once.** Add the entry,
re-`grep` to confirm it survived, attempt the dependent action, check the
observable result, sleep, repeat. `scripts/services.sh` retries every 10 s for
up to four minutes.

The general form of this mistake — logging success because a command did not
return an error — is worth watching for everywhere on this platform.

## USB hotplug regenerates /etc/passwd and breaks bind mounts

Plugging in a second USB device does two destructive things mid-boot, with no
reboot involved:

1. The firmware **regenerates `/etc/passwd`** (setting up share users), which
   deletes the `sshd` privilege-separation account. sshd's listener survives,
   so the port still answers, but every new connection dies before the banner:

       kex_exchange_identification: read: Connection reset by peer

2. **Device nodes renumber** — the boot stick moved `sda` -> `sdc` — so the
   volume is unmounted and remounted, which silently destroys any bind mount
   onto it. `/tmp/opt` disappears and `/opt/sbin/sshd` stops existing.

Anything that sets these up **once per boot will lock you out.** State that the
firmware can destroy at runtime must be *maintained*, not asserted once:
`scripts/services.sh` re-checks the account and the bind mount every 60s and
force-restarts sshd when it had to recreate the account, because a running sshd
with a deleted account is broken but looks healthy.

## script_usbmount fires on EVERY mount event, not just at boot

Which means every stage it launches needs a single-instance guard. Without one,
inserting a second disk started a rival `portal_start.sh` — two supervisors
each killing and restarting the other's lighttpd and collector (observed as
pids 480 and 467 running together). Use an atomic `mkdir` lock released by a
trap, not a stamp file.

## Modern mkfs.ext4 builds filesystems this kernel cannot mount

Entware's e2fsprogs is 1.47, whose ext4 defaults include `64bit`,
`metadata_csum` and `orphan_file`. The 2.6.36 kernel here supports none of
them, and the only symptom is:

    mount: mounting /dev/sdb1 on /tmp/mnt/BTDATA failed: Invalid argument

Disable them explicitly, and note that a **positive `-O` list adds to the
defaults rather than replacing them** — the `^` prefix is required:

    mkfs.ext4 -O ^64bit,^metadata_csum,^orphan_file -F /dev/sdX1

A format of a 128 GB volume takes ~6 minutes here, so validate the option set
on a small image file first: `mke2fs` works on a regular file, and mounting it
with `-o loop` is a definitive test that beats reading feature strings.

## The rootfs cannot be written, at all

    # mount -o remount,rw / ; touch /usr/sbin/.wtest
    touch: /usr/sbin/.wtest: Read-only file system

squashfs is compressed and read-only by construction. No remount helps. This
rules out replacing firmware binaries and stubbing shipped shell scripts.

## `StrictModes` rejects everything under `/opt`

    Authentication refused: bad ownership or modes for directory /tmp

OpenSSH walks the entire path to `authorized_keys`. `/opt` is a symlink to
`tmp/opt`, and `/tmp` is `0777`, so any key file under `/opt` fails no matter
how tight its own permissions are. Put it on `/jffs`. Do not set
`StrictModes no`.

## OpenSSH's privsep account is not optional

`UsePrivilegeSeparation no` was removed from OpenSSH. The `sshd` account must
exist in `/etc/passwd`, and this firmware does not ship one — combine with the
`/etc` regeneration trap above.

## The firmware automounts your data volume too, under a "(1)" name

Both the firmware's automounter and your own script will try to mount a
labelled volume. Whichever loses finds `/tmp/mnt/<LABEL>` taken and falls back
to `/tmp/mnt/<LABEL>(1)`, leaving one device mounted twice:

    /dev/sda1 /tmp/mnt/BTDATA(1) ext4 rw,nodev,relatime,...
    /dev/sda1 /tmp/mnt/BTDATA    ext4 rw,noatime,...

Harmless to the data — Linux shares one superblock between both mounts — but it
double-counts in `df` and in the dashboard's disk list, and it gives torrents
two plausible paths to the same files. `services.sh` treats its own mount as
authoritative and unmounts any duplicate of the same device elsewhere under
`/tmp/mnt`.

Note also that the automounter is unreliable in timing: on one boot it had not
mounted a freshly formatted ext4 volume even after three minutes, and on the
next it got there first. Do not depend on either outcome.

## An in-place `sed` on the router is undone by your next deploy

The single-disk migration changed `USB_LABEL=ROUTERDATA` to `BTDATA` by
`sed`-ing the files **on the router**. The working copies those files were
deployed from still said `ROUTERDATA`, so the next unrelated deploy silently
reverted the label — and the RRD feeder and exporter began resolving a volume
that no longer exists. The feeder exited 0 (correct behaviour for a missing
volume) and the exporter ran `cleanup_exports`, **deleting the history JSON**.

Nothing errored. The dashboard just said "no history" again.

If you edit in place on the device, make the same edit in the source you deploy
from, or stop deploying that file. `grep -H '^USB_LABEL=' ` across both sides
takes a second and would have caught it immediately.

## Resolve mountpoints from /proc/mounts, not blkid

`blkid` opens every block device it can find. On a box whose USB bus is
saturated — a torrent writing at 1 MB/s, say — that is a real cost, and a probe
that returns nothing is indistinguishable from "the volume is gone" to a script
that treats it as authoritative. In this project that path *deletes* exported
history.

`/proc/mounts` is a kernel file, needs no device access, and cannot fail that
way:

    awk -v l="$LABEL" '$2 ~ ("^/tmp/mnt/" l "(\\([0-9]+\\))?$") {print $2; exit}' /proc/mounts

The optional `(N)` also handles the automounter suffix below. `blkid` is still
the right tool when you need the *device node* of a volume that is not mounted
yet — that is the one case `/proc/mounts` cannot answer.

## The automounter sometimes uses /tmp/mnt/<LABEL>(1) even with nothing at the plain name

Separate from the duplicate-mount entry below, and more insidious. After one
reboot the boot volume came up mounted **only** at `/tmp/mnt/ROUTERDATA(1)`,
with `/tmp/mnt/ROUTERDATA` not existing at all:

    /dev/sdc1 /tmp/mnt/ROUTERDATA(1) ext3 ...
    /dev/sdc1 /tmp/opt               ext3 ...

Anything resolving the volume dynamically kept working — `services.sh` found it
by label, so `/opt`, SSH and Entware were all fine. Anything with a **hardcoded**
`/tmp/mnt/<LABEL>` silently did nothing: `rrd_feeder.sh` and `rrd_export.sh`
failed their mount check and exited 0, so the history stopped being collected
and the dashboard reported "no history" while the databases sat intact a few
characters away.

**Never hardcode `/tmp/mnt/<LABEL>`.** Resolve it:

    dev=$(blkid | grep "LABEL=\"$LABEL\"" | cut -d: -f1)
    mp=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)

Note the mountpoint can then contain parentheses, so every use of it must be
quoted.

## Device nodes are not stable

The USB stick moved from `/dev/sda1` to `/dev/sdb1` across a single
unplug/replug, with no second disk present. Resolve volumes by label or UUID
and find the mountpoint in `/proc/mounts`.

## `tune2fs -L` silently reverts

Two separate mechanisms undo a relabel, both observed here:

1. **Relabelled while mounted** — the kernel holds the superblock in memory and
   flushes its cached copy, with the old label, on unmount. The new label can
   appear to work for a while and then revert at the next reboot.
2. **Relabelled with a dirty journal** — a later `e2fsck` replays the journal
   and restores the old superblock.

Order: `umount`, `e2fsck -p`, `tune2fs -L`, `sync`, then verify with a *second*
`e2fsck` followed by `blkid`.

## `LD_LIBRARY_PATH` kills Entware binaries launched from `rc`

`rc` exports it pointing at firmware libraries; it beats the `DT_RUNPATH` in
Entware binaries, which then load the wrong libc and die. `rc.func` discards
stderr, so the symptom is a service that simply never starts — and that works
perfectly when you run it by hand, because interactive sessions do not inherit
the variable.

    ( unset LD_LIBRARY_PATH LD_PRELOAD ; /opt/bin/whatever )

## A signal trap that does not exit leaves the process running and unlocked

    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM     # WRONG

A shell resumes execution after a signal handler returns. So on SIGTERM this
releases the lock and **keeps running** — `killall` appears to do nothing, and
the next launch acquires the now-free lock and starts a duplicate. Observed
exactly that: two `portal_start.sh` and two `transmission.sh` at once.

    _cleanup() { rmdir "$LOCKDIR" 2>/dev/null; }          # RIGHT
    trap '_cleanup' EXIT
    trap '_cleanup; exit 143' TERM
    trap '_cleanup; exit 130' INT

Related: **busybox `ash` defers traps until the running command finishes.** A
stage sitting in `sleep 60` will not react to SIGTERM for up to a minute, so a
`killall` followed by a three-second check reports failure while the signal is
simply still queued. Wait out the interval before concluding anything, and use
`kill -9` only when you have.

## A hung process does not answer SIGTERM

`killall foo` sends SIGTERM, which a stopped or otherwise wedged process never
handles. It stays in state `T`, `pidof` keeps matching it, and every restart
leaks another one:

    2673 admin  T  /bin/sh /jffs/portal/portal_collector.sh   <- "killed" 3 minutes ago
    3360 admin  S  /bin/sh /jffs/portal/portal_collector.sh   <- the replacement

Since the whole point of the restart is that the process is *not responding*,
SIGTERM is the wrong tool for exactly the case you are handling. Send TERM,
wait, then KILL:

    killall foo 2>/dev/null; sleep 1; killall -9 foo 2>/dev/null

SIGKILL is delivered regardless of stop state. Note that a process wedged in
uninterruptible sleep (state `D`, which is what a blocked `wl` ioctl actually
produces) will not die even then — which is the real reason to bound those
calls rather than rely on cleaning up afterwards.

This was found by `kill -STOP` testing the supervisor, not by reading the code.

## Shell arithmetic overflows silently at 2^31

busybox `ash` truncates with no error. Interface byte counters pass 2^31 within
days of uptime, so anything doing shell arithmetic on them starts producing
zeroes that look like idle links. Do the maths in `awk`, which uses doubles.

## busybox awk reads `var (` as a function call

    arr = arr (arr == "" ? "" : ",") row      # "Call to undefined function"

String concatenation with a parenthesised expression immediately after a
variable name is ambiguous, and busybox awk resolves it as a call to a function
named `arr`. The program dies at parse time, so the whole script silently
produces nothing — which surfaced as a dashboard reporting "0 torrents" while
transmission was plainly downloading.

Split it, or put an operator between:

    if (arr != "") arr = arr ","
    arr = arr row

## A backgrounded subshell hides the pid you need to kill

    ( cmd > "$tmp" ) &
    p=$!            # the SUBSHELL's pid, not cmd's
    kill -9 "$p"    # kills the subshell; cmd is orphaned and keeps running

The orphan then writes into `$tmp` after the timeout has "expired", clobbering
whatever the *next* call put there. With a shared temp path that means one
call's output arrives in another's buffer, intermittently, only under load.

Use `exec` so the subshell is replaced by the command and `$!` is the command
itself, and give each call its own temp file:

    ( unset LD_LIBRARY_PATH; exec "$@" > "$tf" ) &

## Missing utilities

This is a thinner busybox than the GT-AC5300's. Absent, among others:

    id      od      timeout      uniq

`timeout` in particular has no replacement, and bounding a call that can hang
is not optional here — see the `wl_to()` helper in
`scripts/portal/portal_collector.sh` for the backgrounded-poll pattern used
instead.

Check before relying on anything outside the obvious core.

## `$HOME` is tmpfs

`/root` is a symlink to `/tmp/home/root`. Anything writing config to `$HOME`
loses it on reboot.

## dnsmasq lease times are SECONDS REMAINING, not an absolute expiry

A direct consequence of the missing RTC below. Standard dnsmasq writes an
absolute epoch in field 1 of `dnsmasq.leases`; ASUS builds it with
`HAVE_BROKEN_RTC`, which stores the **remaining lease time** instead:

    86400 8c:1d:96:ee:f5:d9 192.168.1.226 DESKTOP-FHLIGI7 01:8c:1d:...
    85727 60:d8:9c:71:06:40 192.168.1.4   Nokia-X20       01:60:d8:...

86400 is exactly `nvram get dhcp_lease`, and the second value is that minus the
elapsed time — the giveaway. Feeding it to `new Date(v * 1000)` renders every
lease as **January 1970**, which is how this surfaced.

Prefer the remaining time when displaying it: it stays correct even while the
clock is wrong, which on this platform is every boot before NTP syncs. Derive an
absolute expiry as `now + remaining` only as a convenience, and treat `0` as an
infinite/static lease.

## There is no RTC — the clock is wrong until NTP

With no WAN connection the router boots believing it is 2018. This matters for
anything time-series: rrdtool rejects updates older than the last one, so a
multi-year jump when NTP finally syncs will corrupt a database. Confirm `date`
is sane before starting any collector.

## ASUS `httpd` owns port 80

On the LAN address and on loopback. Bind anything of your own elsewhere.

## Do not plug the WAN port into the router's own LAN

Obvious in hindsight, silent in practice. The WAN DHCP client will take a lease
from the router's *own* DHCP server and set the router as its own gateway:

    wan0_ipaddr  = 192.168.1.20
    wan0_gateway = 192.168.1.1
    ping 1.1.1.1 -> Network is unreachable

Both sides then sit on `192.168.1.0/24` and nothing routes. `link_internet=1`
still reads as success, so trust `ping`, not the flag.

## The web API session expires quickly

Scripted `appGet.cgi` work stops returning JSON and starts returning a redirect
to `Main_Login.asp` after a short idle period. Re-authenticate rather than
concluding that the endpoint broke.
