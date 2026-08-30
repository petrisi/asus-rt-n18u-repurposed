# Getting a shell

**Stock firmware has no SSH at all.** Not disabled — absent. This is the first
place the RT-N18U diverges sharply from the GT-AC5300, where SSH ships and is
merely switched off.

Three independent confirmations, worth repeating on your own unit before you
go looking for a setting that is not there:

    # nvram get rc_support | tr ' ' '\n' | grep -i ssh
    (nothing)

    # which dropbear dropbearkey
    (nothing)

The web GUI shows only *Enable Telnet* under Administration -> System, with no
SSH section, because the page is shared across models and hides features the
build does not advertise. Writing `sshd_enable` / `sshd_authkeys` into nvram
"succeeds" and then silently does nothing — httpd discards nvram for features
the firmware does not ship. Do not spend an evening on this.

## Step 1: telnet, temporarily

Web GUI -> **Administration -> System -> Enable Telnet: Yes**, then Apply.

    telnet 192.168.1.1
    login: admin
    password: <your router admin password>

That is a root BusyBox shell (`uid 0`, prompt `admin@RT-N18U:/tmp/home/root#`).

**Telnet is cleartext, including that password.** Before enabling it, either
put the router on a cable with nothing else on the segment, or turn the radio
off (Wireless -> Professional -> Enable Radio: No). A weak Wi-Fi passphrase and
telnet on the same LAN is the worst combination in this repository.

Telnet is a bootstrap, not a destination. It gets turned off in step 5.

## Step 2: install OpenSSH

Follow [04-usb-and-entware.md](04-usb-and-entware.md) first — SSH here comes
from Entware, so the USB stick and `/opt` have to exist before this works.

    unset LD_LIBRARY_PATH LD_PRELOAD
    /opt/bin/opkg update
    /opt/bin/opkg install openssh-server

You get a current OpenSSH, not a decade-old dropbear. None of the
`HostKeyAlgorithms +ssh-rsa` client workarounds the GT-AC5300 needs apply here;
ed25519 keys work normally.

    ssh-keygen -t ed25519 -f ~/.ssh/rtn18u

## Step 3: the privilege-separation account

    Privilege separation user sshd does not exist

OpenSSH refuses to start without a dedicated `sshd` account, and this
firmware's `/etc/passwd` has only `admin`, `nas` and `nobody`.
`UsePrivilegeSeparation no` was removed from OpenSSH years ago, so it cannot be
opted out of.

    grep -q '^sshd:' /etc/passwd || \
        echo 'sshd:x:22:22:sshd privsep:/var/empty:/bin/false' >> /etc/passwd
    grep -q '^sshd:' /etc/group  || echo 'sshd:x:22:' >> /etc/group
    mkdir -p /var/empty && chmod 755 /var/empty

**`/etc` is a symlink into tmpfs and the firmware regenerates it during boot**,
so this is lost on every reboot *and* can be wiped out from under a boot script
that adds it too early. `scripts/services.sh` handles that with a retry loop —
see `02-persistence.md` and `99-gotchas.md`.

## Step 4: configuration that actually works here

Generate host keys and place your public key, then set four things in
`/opt/etc/ssh/sshd_config`:

    ssh-keygen -t ed25519 -f /opt/etc/ssh/ssh_host_ed25519_key -N ""
    ssh-keygen -t rsa -b 2048 -f /opt/etc/ssh/ssh_host_rsa_key -N ""

    mkdir -p /jffs/.ssh && chmod 700 /jffs/.ssh
    echo 'ssh-ed25519 AAAA... you@host' > /jffs/.ssh/authorized_keys
    chmod 600 /jffs/.ssh/authorized_keys

    AuthorizedKeysFile   /jffs/.ssh/authorized_keys
    PermitRootLogin      prohibit-password
    PasswordAuthentication no
    ListenAddress        192.168.1.1

Two of those are not optional:

**`AuthorizedKeysFile` must not be under `/opt`.** `StrictModes` walks the
whole path and rejects world-writable directories. `/opt` is a symlink to
`tmp/opt`, and `/tmp` is `0777`:

    Authentication refused: bad ownership or modes for directory /tmp

`/jffs` (`0755`, under `/` at `0755`) passes. The tempting fix — `StrictModes
no` — throws away a real check because of a path choice you can simply avoid.

**`ListenAddress` matters.** Without it sshd binds `0.0.0.0`, which includes
the WAN interface. Binding the LAN address is one line and removes the question
entirely.

`PermitRootLogin` does apply despite the account being called `admin`: OpenSSH
keys that setting off uid 0, not off the literal name `root`.

Verify from your workstation before going further:

    ssh -i ~/.ssh/rtn18u admin@192.168.1.1 'echo OK; uname -a'

## Step 5: turn telnet off

Only once the key login above works, and ideally only after it has survived a
reboot (`02-persistence.md`):

    nvram set telnetd_enable=0
    nvram commit
    killall telnetd

If you ever need it back, it is a GUI toggle — which is also your recovery path
if a change to `sshd_config` locks you out. That is the reason telnet goes last
and not first.

## A word on the shell

BusyBox 1.17.4 `ash`. It is not bash, and it is a thinner busybox than the
GT-AC5300's — several utilities you will reach for reflexively are absent:

    # id
    -sh: id: not found
    # od
    -sh: od: not found

`$HOME` is `/root`, a symlink to `/tmp/home/root`, which is tmpfs. Anything
writing config to `$HOME` loses it on reboot. Point such tools at the USB
volume explicitly.

Read `99-gotchas.md` before writing anything non-trivial.
