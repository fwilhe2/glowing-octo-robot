# --disable-liblastlog2: it needs libsqlite3, which does not ship, and its unit would fail
#   every boot. --disable-pylibmount: python bindings (constraint 5), off today only
#   because the builder lacks python3-dev. --without-udev: lsblk and findmnt would link
#   libudev, which the container image deletes; lsblk falls back to sysfs.
# --disable-makeinstall-setuid: nothing in the image is setuid (su, mount, umount would be).
#
# The rest is a denylist, and has to be: --disable-all-programs cannot be undone for the
# third of programs without an --enable switch (findmnt, flock, setsid, getopt, mkswap,
# column...). What stays is the login path, the mount and filesystem tools, the namespace
# tools, and what a person at the console reaches for. What goes is partitioning (the
# image has no partition table; systemd is built without libfdisk's callers), filesystems
# the kernel lacks, hardware a VM lacks (hwclock, rfkill, eject, zram, watchdogs), SysV
# IPC, the utmp tools (nothing writes utmp), switch_root (no initramfs), and the old long
# tail.
./configure \
    --prefix=/usr \
    --disable-asciidoc \
    --disable-poman \
    --disable-nls \
    --disable-liblastlog2 \
    --without-udev \
    --disable-pylibmount \
    --disable-fdisks \
    --disable-libfdisk \
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
    --disable-lslogins \
    --disable-makeinstall-setuid

make
make install DESTDIR=$ROOTFS

assert_not_linked libudev usr/bin/lsblk usr/bin/findmnt

# The same judgement for programs with no configure switch.
drop_installed colrm look namei lsclocks mcookie uuidparse ldattach rtcwake readprofile \
               ctrlaltdel isosize blkzone blkpr swaplabel fadvise
