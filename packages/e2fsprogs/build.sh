# e2fsprogs installs a filesystem-forensics kit alongside the four tools this image
# actually needs. `mke2fs`, `e2fsck`, `tune2fs` and `resize2fs` stay — the first two
# because image/build-rootfs.sh and systemd-fsck call them, the last because growing
# the root filesystem on first boot is a real thing to want from a VM image.
#
# What configure can be told not to build:
#
#   debugfs     an interactive filesystem debugger, 646 KB. The largest single one.
#   imager      e2image, which dumps filesystem metadata for offline analysis.
#   defrag      e4defrag. ext4 does not need it and the image is written once.
#   uuidd       a daemon for handing out UUIDs to concurrent callers. util-linux's
#               uuidd is disabled for the same reason; nothing here generates UUIDs
#               under contention, or at all after mke2fs.
#   fuse2fs     mounting ext4 through FUSE. There is no libfuse in the image and no
#               CONFIG_FUSE_FS in vm.config — so this is off by absence today, and
#               naming it is the same discipline as the --without- list in
#               packages/curl/build.sh.
#   nls         the image is C-locale only and the trim deletes share/locale.
#   e2initrd-helper  tells an initramfs which module to load for the root filesystem.
#               There is no initramfs — qemu is handed the kernel directly — and no
#               modules either, CONFIG_MODULES being off. 361 KB in usr/lib that
#               nothing could ever exec.
#
# --enable-mmp is deliberately left alone. Multi-Mount Protection is a filesystem
# feature rather than a tool, and turning it off would make e2fsck unable to read an
# image that has it set. e2mmpstatus goes with it and would save nothing anyway, being
# a hardlink of dumpe2fs.
./configure \
    --prefix=/usr \
    --disable-debugfs \
    --disable-imager \
    --disable-defrag \
    --disable-uuidd \
    --disable-fuse2fs \
    --disable-nls \
    --disable-e2initrd-helper

make
make install DESTDIR=/usr/local/rootfs

# The rest have no configure switch, so they go after the install. Same reasoning:
# badblocks scans for media errors on a virtual disk that reports none, e4crypt
# manages ext4 encryption keys (no CONFIG_FS_ENCRYPTION), e2undo replays an undo file
# mke2fs is never asked to write, e2freefrag and filefrag report fragmentation nobody
# is going to act on, and mklost+found creates a directory mke2fs has already made.
# logsave wraps a command's output into a log file for a boot sequence that is
# systemd's here.
#
# compile_et and mk_cmds are the odd ones: they are code generators — they turn an
# error-table or command-table description into C for a compiler to build. That is the
# same argument the trim already makes for usr/include and the .a files, in binary form.
#
# The loop insists each name is present before removing it, so that a rename upstream
# fails the build rather than silently shipping the binary. See the same pattern in
# packages/util-linux/build.sh.
for prog in badblocks e4crypt e2undo e2freefrag filefrag mklost+found logsave \
            compile_et mk_cmds; do
    if [ ! -e "/usr/local/rootfs/usr/bin/$prog" ]; then
        echo "e2fsprogs: $prog is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "/usr/local/rootfs/usr/bin/$prog"
done

# e2scrub is an online-consistency-check harness: two shell scripts, a cron job, udev
# rules and five systemd units that snapshot an LVM volume and fsck the snapshot. There
# is no LVM here (vm.config clears device-mapper) so it could never do anything, and a
# timer unit whose script is missing is exactly how a boot ends up `degraded`. The cron
# file is its own small absurdity — there is no cron in this image either.
#
# Unchecked, unlike the loop above: which of these get installed depends on what
# configure found — the systemd and cron pieces are conditional — so absence is normal
# here rather than a sign the list has gone stale.
rm -f /usr/local/rootfs/usr/bin/e2scrub /usr/local/rootfs/usr/bin/e2scrub_all
rm -f /usr/local/rootfs/usr/bin/e2scrub_all_cron
rm -f /usr/local/rootfs/etc/e2scrub.conf
rm -f /usr/local/rootfs/etc/cron.d/e2scrub_all
rm -rf /usr/local/rootfs/usr/libexec/e2fsprogs
rm -f /usr/local/rootfs/usr/lib/systemd/system/e2scrub*
rm -f /usr/local/rootfs/usr/lib/udev/rules.d/*e2scrub.rules
rm -f /usr/local/rootfs/usr/lib/udev/rules.d/*ext4.rules
