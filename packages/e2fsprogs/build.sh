# The four tools an ext4 data disk needs (mke2fs, e2fsck, tune2fs, resize2fs; systemd-fsck
# and makefs call them), and not the forensics kit around them. --disable-fsck because
# util-linux installs the same path. --enable-elf-shlibs, or each tool carries its own
# copy of libext2fs.
./configure \
    --prefix=/usr \
    --disable-debugfs \
    --disable-imager \
    --disable-defrag \
    --disable-uuidd \
    --disable-fuse2fs \
    --disable-nls \
    --disable-fsck \
    --disable-e2initrd-helper \
    --enable-elf-shlibs

make
make install DESTDIR=$ROOTFS

# The rest have no configure switch. compile_et and mk_cmds generate C at build time.
drop_installed badblocks e4crypt e2undo e2freefrag filefrag mklost+found logsave \
               compile_et mk_cmds

# libss is debugfs's command parser, and debugfs is off.
rm -f $ROOTFS/usr/lib/libss.so*

# e2scrub fscks LVM snapshots: no LVM, no cron, and a unit whose script is missing would
# degrade the boot. Unchecked, since which pieces install depends on what configure found.
rm -f $ROOTFS/usr/bin/e2scrub $ROOTFS/usr/bin/e2scrub_all
rm -f $ROOTFS/usr/bin/e2scrub_all_cron
rm -f $ROOTFS/etc/e2scrub.conf
rm -f $ROOTFS/etc/cron.d/e2scrub_all
rm -rf $ROOTFS/usr/libexec/e2fsprogs
rm -f $ROOTFS/usr/lib/systemd/system/e2scrub*
rm -f $ROOTFS/usr/lib/udev/rules.d/*e2scrub.rules
rm -f $ROOTFS/usr/lib/udev/rules.d/*ext4.rules
