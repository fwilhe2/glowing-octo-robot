# For libelf.so.1 alone, which libbpf, ip and tc link. Debuginfod is a dummy (its real
# client wants curl, microhttpd and sqlite); no bzip2. elfutils has -Werror in AM_CFLAGS
# and no switch for it; CFLAGS comes after, so -Wno-error is appended to the exported
# flags (passing CFLAGS replaces the environment's, which carries the sysroot).
./configure --prefix=/usr --libdir=/usr/lib \
  --disable-debuginfod --enable-libdebuginfod=dummy \
  --without-bzlib \
  --disable-nls \
  CFLAGS="${CFLAGS:-} -Wno-error"
make
make install DESTDIR=$ROOTFS

# The eu-* tools, which cannot be configured away (and eu-srcfiles would link libarchive).
rm -f $ROOTFS/usr/bin/eu-*

# Everything else that is not libelf: libdw and libasm (systemd is built without
# coredump, its only consumer), the dummy debuginfod and its client and profile snippets.
rm -f $ROOTFS/usr/lib/libdw[.-]* $ROOTFS/usr/lib/libasm[.-]* $ROOTFS/usr/lib/libdebuginfod[.-]*
rm -rf $ROOTFS/usr/etc/profile.d/debuginfod.* $ROOTFS/usr/share/fish/vendor_conf.d/debuginfod.fish
drop_installed debuginfod-find
