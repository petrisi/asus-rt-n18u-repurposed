# USB storage and Entware

Entware gives you `opkg` and a few thousand packages, on a kernel from 2010
that can otherwise run almost nothing modern. On this model it is also where
SSH comes from, so it is a dependency of `01-getting-shell.md`, not an optional
extra.

It lives on the USB stick. `/jffs` is small NAND you will never reflash.

## Format the stick

**ext3 is fine, and the firmware cannot create ext4 — but the kernel mounts
it.** The shipped tools are only:

    /sbin/mkfs.ext2   /sbin/mkfs.ext3   /sbin/mke2fs   /sbin/tune2fs

`ext4` is nonetheless in `/proc/filesystems` with the module loaded, so an ext4
volume created elsewhere — or by Entware's `e2fsprogs`, which provides
`mkfs.ext4` — mounts normally. See the feature-compatibility trap in
[99-gotchas.md](99-gotchas.md) before creating one.

For the boot stick, ext3 is entirely adequate: the properties that matter are
real Unix permissions and symlinks, and both are present. Do not reformat a
working ext3 stick for the version number.

    mkfs.ext3 -L ROUTERDATA /dev/sda1     # destructive

## Labelling an existing stick: read this first

If the stick already has data and you only want to relabel it, `tune2fs -L`
will **silently revert** unless the volume is both unmounted and journal-clean.
This bit twice during setup, by two different mechanisms. Correct order:

    umount /tmp/mnt/<current>      # or umount -l if busy
    e2fsck -p /dev/sda1            # replay the journal FIRST
    tune2fs -L ROUTERDATA /dev/sda1
    sync
    blkid                          # verify
    e2fsck -p /dev/sda1 ; blkid    # verify again — a label that survives this is real

Full explanation in [99-gotchas.md](99-gotchas.md).

## Install Entware — the right target

**`armv7sf-k2.6`. Not `k3.2`, not `aarch64`.**

The kernel here is 2.6.36 and the userland is 32-bit ARM soft-float, so the
2.6 target is the correct one. The GT-AC5300 uses `armv7sf-k3.2`; picking that
one here is the obvious mistake.

`/opt` is a **dangling** symlink out of the box — it points at `tmp/opt`, which
does not exist:

    # readlink /opt
    tmp/opt
    # ls -ld /tmp/opt
    ls: /tmp/opt: No such file or directory

So create the target, then bind the stick over it:

    mkdir -p /tmp/opt
    mkdir -p /tmp/mnt/ROUTERDATA/entware
    mount -o bind /tmp/mnt/ROUTERDATA/entware /tmp/opt
    wget -O - https://bin.entware.net/armv7sf-k2.6/installer/generic.sh | sh

`/opt` must be that bind mount — the path is baked into every Entware package.
`/tmp` is tmpfs, so **both the directory and the bind are lost at every boot**
and must be recreated; `scripts/services.sh` does it.

The firmware's `wget` does support HTTPS, so the installer works unmodified.

## The trap that will cost you an evening

**Every Entware binary fails when launched from `rc`, silently.**

`rc` exports `LD_LIBRARY_PATH` pointing at the firmware's own libraries. Entware
binaries carry a `DT_RUNPATH`, but an inherited `LD_LIBRARY_PATH` wins over
`DT_RUNPATH`, so they load the wrong libc and die. `rc.func` discards stderr,
so there is no message — just a service that never starts.

Unset it before launching anything from `/opt`:

    (
      unset LD_LIBRARY_PATH LD_PRELOAD
      /opt/bin/whatever
    )

Every script here that touches `/opt` does this. Interactive sessions do not
inherit the variable, which is exactly why something works by hand and fails at
boot — the most confusing possible symptom.

## Useful packages

    opkg update
    opkg install openssh-server        # see 01-getting-shell.md
    opkg install htop tcpdump screen rrdtool

`tcpdump` is worth calling out: the stock firmware has none, and there is no
other way to see what this box is actually sending.

## A note on `$HOME`

`/root` is a symlink to `/tmp/home/root`, which is tmpfs. Anything that writes
configuration to `$HOME` loses it on reboot. Point such tools at the USB volume
explicitly:

    screen -c /tmp/mnt/ROUTERDATA/screenrc

This is also why `authorized_keys` does not live in `/root/.ssh` — though the
reason it lives on `/jffs` rather than the stick is a different one entirely.
See `01-getting-shell.md`.
