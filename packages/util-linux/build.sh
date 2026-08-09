# --disable-liblastlog2: lastlog2 links libsqlite3, which we don't ship, so the
# lastlog2-import.service that util-linux installs alongside it fails at every boot
# with status 127 and leaves the system `degraded`. Its ConditionPathExists is met
# because systemd's own var.conf tmpfiles snippet creates /var/log/lastlog. Disabling
# the feature drops the binary, liblastlog2, pam_lastlog2 (which _files/etc/pam.d
# doesn't reference) and the unit itself, so there is nothing left to fail.
#
# --disable-nls: the image is C-locale only and the trim deletes share/locale, so the
# catalogues would be built and installed to be thrown away. Same reason
# packages/iputils/build.sh passes USE_GETTEXT=false. --disable-poman is the same
# argument for the translated man pages, which --disable-asciidoc already leaves
# nothing to translate.
#
# --disable-pylibmount is constraint 5 in its clearest form: it builds python bindings
# for libmount and installs them into the image. It is off today only because the
# builder image has no python3-dev for configure to find, which is luck rather than a
# decision — the same shape as the --without- list in packages/curl/build.sh.
#
# THE REST OF THIS FILE IS A DENYLIST, AND IT HAS TO BE.
#
# util-linux offers --disable-all-programs, which reads like the right tool: it would
# turn this into an allowlist, the way packages/systemd/build.sh's fifty -D...=false
# lines effectively are. Do not use it. It sets ul_default_estate=no, which
# m4/ul.m4's UL_DEFAULT_ENABLE then applies to *everything*, and only a program with an
# AC_ARG_ENABLE of its own can be switched back on. Roughly a third have none, and the
# casualties are not obscure: findmnt, flock, blockdev, setsid, prlimit, findfs, getopt,
# mkswap, col and column would all be gone with no way to ask for them back. It is a
# one-way door with no handle on the other side, so the removals below are named one at
# a time.
#
# The same flag would also take libuuid, libblkid, libmount and libsmartcols with it —
# those *are* recoverable, having --enable- switches, but three of them are load-bearing
# for the boot rather than for a person: systemd links libmount and libblkid, and
# e2fsprogs links libuuid and libblkid.
#
# What stays, so that the list below can be read as "everything else": the login path
# (agetty, login, sulogin, su, runuser, nologin), the mount and filesystem path (mount,
# umount, mountpoint, findmnt, findfs, fsck, blkid, wipefs, blockdev, losetup, fstrim,
# lsblk, mkfs, mkswap, swapon/swapoff), the namespace tools constraint 3 wants (nsenter,
# unshare, setpriv, lsns, pivot_root), and the things a person at the serial console
# actually reaches for (dmesg, kill, flock, logger, prlimit, setsid, getopt, uuidgen,
# hexdump, col, column, more, lscpu, lsmem, lsfd, lslocks, setarch). systemd invokes
# several of those directly, which is why this list is longer than a minimal one.
#
# What goes is hardware we do not have, filesystems we do not build, subsystems with no
# consumer, and a long tail that is here because util-linux is thirty years old:
#
#   fdisks, partx     partition table editors. The image is a single filesystem written
#                     by `mkfs.ext4 -d`; there is no partition table to edit, and
#                     dropping partx takes addpart/delpart/resizepart with it.
#   cramfs, bfs,      mkfs and fsck for three filesystems the kernel does not build.
#   minix             vm.config already clears them.
#   hwclock           systemd owns the clock here, and a virtio guest has no RTC policy
#                     to set. Same reason systemd is built -Dhibernate=false.
#   rfkill            radio kill switches, on a machine with no radio — systemd is
#                     already built -Drfkill=false for exactly this.
#   eject, zramctl,   removable media, compressed swap, watchdogs and CPU/memory
#   wdctl, chmem      hotplug. None exists in the target VM.
#   ipcmk, ipcrm,     System V IPC tooling. Nothing here uses SysV IPC.
#   ipcs
#   irqtop, lsirq     interrupt monitors, for tuning hardware we do not have.
#   last, utmpdump    the utmp/wtmp login database, which nothing writes: systemd-logind
#                     and journald are the session record here.
#   scriptutils       script/scriptlive/scriptreplay record a terminal session to a
#                     typescript file. The console is a serial line the tests parse.
#   chfn-chsh         editing GECOS and shells in /etc/passwd, which the image ships
#                     complete and read-only in practice.
#   cal, whereis,     the long tail: a calendar, a path search that needs the man and
#   rename, mesg,     source trees the trim deletes, a batch renamer, terminal write
#   wall, ul,         permissions, a broadcast to logged-in users, two nroff-era text
#   setterm, raw      filters, and a deprecated raw-device binding.
#   pipesz, waitpid,  recent small additions with no caller here.
#   enosys, exch,
#   bits, getino,
#   copyfilerange
#   hardlink          a deduplicator for a read-only image.
#   switch_root       for an initramfs handing off to the real root. There is no
#                     initramfs: qemu is handed the kernel directly. pivot_root stays,
#                     being the container-namespace half of the pair.
#   uuidd             a daemon for handing out UUIDs to concurrent callers. uuidgen
#                     stays and needs nothing.
#   lslogins          reads the utmp database and shadow; nothing here asks it to.
./configure \
    --prefix=/usr \
    --disable-asciidoc \
    --disable-poman \
    --disable-nls \
    --disable-liblastlog2 \
    --disable-pylibmount \
    --disable-fdisks \
    --disable-partx \
    --disable-cramfs \
    --disable-bfs \
    --disable-minix \
    --disable-hwclock \
    --disable-rfkill \
    --disable-eject \
    --disable-zramctl \
    --disable-wdctl \
    --disable-chmem \
    --disable-ipcmk \
    --disable-ipcrm \
    --disable-ipcs \
    --disable-irqtop \
    --disable-lsirq \
    --disable-last \
    --disable-utmpdump \
    --disable-scriptutils \
    --disable-chfn-chsh \
    --disable-cal \
    --disable-whereis \
    --disable-rename \
    --disable-mesg \
    --disable-wall \
    --disable-ul \
    --disable-setterm \
    --disable-raw \
    --disable-pipesz \
    --disable-waitpid \
    --disable-enosys \
    --disable-exch \
    --disable-bits \
    --disable-getino \
    --disable-copyfilerange \
    --disable-hardlink \
    --disable-switch_root \
    --disable-uuidd \
    --disable-lslogins

make
make install DESTDIR=/usr/local/rootfs

# The ones with no AC_ARG_ENABLE, per the note above: configure cannot be asked not to
# build them, so they are removed after the install rather than left to ship. This is
# the same judgement as every --disable- line above and not a different one — the only
# difference is that upstream never gave these a switch.
#
# Console and terminal filters from an era of paper (colrm, look), hardware that is not
# here (ldattach for serial line disciplines, rtcwake, readprofile for a kernel built
# without profiling, ctrlaltdel, blkzone for zoned block devices, blkpr for SCSI
# persistent reservations, isosize for CD images), and small queries with no caller
# (namei, lsclocks, mcookie, uuidparse, swaplabel, fadvise).
#
# The loop insists each name is really there rather than using a bare `rm -f`. A plain
# `rm -f` of a name upstream has renamed removes nothing and says nothing, and the
# binary ships — which is the exact failure mode CLAUDE.md's "breaks silently" section
# is about. Every name below is a program this version installs, so absence means the
# list has gone stale and the build should say so.
for prog in colrm look namei lsclocks mcookie uuidparse ldattach rtcwake readprofile \
            ctrlaltdel isosize blkzone blkpr swaplabel fadvise; do
    if [ ! -e "/usr/local/rootfs/usr/bin/$prog" ]; then
        echo "util-linux: $prog is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "/usr/local/rootfs/usr/bin/$prog"
done
