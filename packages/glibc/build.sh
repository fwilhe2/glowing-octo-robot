mkdir -p build
pushd build
# --disable-werror: sid's linux-libc-dev redefines OPEN_TREE_CLONE etc. that glibc's
# own sys/mount.h also defines, which -Werror turns into a fatal build error.
../configure --prefix=/usr --disable-werror
make
make install DESTDIR=$ROOTFS
popd

# Generators, the malloc/loader debugging tools, the timezone compiler (packages/tzdata
# ships compiled data) and a static ln for repairing systems. Kept: ldconfig, ldd, iconv,
# locale, getent, getconf.
drop_installed gencat makedb iconvconfig localedef mtrace sotruss sprof pcprofiledump \
               xtrace pldd sln zic zdump tzselect

# nscd cannot start (it links libselinux) and nsswitch.conf does not use it. Unchecked:
# which of its files install depends on the build.
rm -f $ROOTFS/usr/bin/nscd
rm -f $ROOTFS/etc/nscd.conf
rm -f $ROOTFS/usr/lib/systemd/system/nscd.service
rm -f $ROOTFS/usr/lib/tmpfiles.d/nscd.conf
