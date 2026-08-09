mkdir -p build
pushd build
# --disable-werror: sid's linux-libc-dev redefines OPEN_TREE_CLONE etc. that glibc's
# own sys/mount.h also defines, which -Werror turns into a fatal build error.
../configure --prefix=/usr --disable-werror
make
make install DESTDIR=/usr/local/rootfs
popd

# glibc's install includes a developer's toolkit that a runtime image cannot reach. This
# is the usr/include argument in binary form: image/build-rootfs.sh already deletes the
# headers, the static libraries and the pkg-config data on the grounds that nothing in
# the image can use them, and a program whose output is input to a compiler is the same
# case.
#
#   gencat, makedb,   generators. gencat compiles a message catalogue, makedb builds an
#   iconvconfig,      nss db, iconvconfig caches the gconv module list, localedef
#   localedef         compiles a locale from share/i18n — which the trim deletes,
#                     the image being C-locale only.
#   mtrace, sotruss,  the malloc/loader debugging set, all of which want a program built
#   sprof,            with the matching instrumentation and a source tree to point at.
#   pcprofiledump,    (mtrace is the POSIX-shell variant here, not the perl one — see
#   xtrace, pldd      CLAUDE.md's constraint 5 — but a shell script with nothing to
#                     trace is still nothing to ship.)
#   zic, zdump,       the timezone toolchain. There is no usr/share/zoneinfo in the
#   tzselect          image at all, so these compile and inspect a database that does
#                     not exist.
#   sln               a statically linked `ln`, for repairing a system whose dynamic
#                     loader is too broken to run the real one. This image is
#                     assembled, not repaired: there is no state to recover, and the
#                     answer to a broken loader is to build it again.
#
# Kept, so the list reads as deliberate: ldconfig (image/build-rootfs.sh runs it), ldd,
# iconv, locale, getent and getconf — the last four being things a person debugging a
# booted machine actually types.
for prog in gencat makedb iconvconfig localedef mtrace sotruss sprof pcprofiledump \
            xtrace pldd sln zic zdump tzselect; do
    if [ ! -e "/usr/local/rootfs/usr/bin/$prog" ]; then
        echo "glibc: $prog is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "/usr/local/rootfs/usr/bin/$prog"
done

# nscd is a special case among those: it is not merely unused, it cannot start. It links
# libselinux.so.1, which this image does not ship — that is the entry it holds in
# test/known-missing-libs.txt, and the reason CLAUDE.md's "already on the allowlist"
# warning is written in terms of nscd. nsswitch.conf names no source that would consult
# it either.
#
# Its configuration and unit go with it, unchecked: a service file whose binary is
# missing is how a boot ends up `degraded`, and which of these glibc's install writes
# depends on the build.
rm -f /usr/local/rootfs/usr/bin/nscd
rm -f /usr/local/rootfs/etc/nscd.conf
rm -f /usr/local/rootfs/usr/lib/systemd/system/nscd.service
rm -f /usr/local/rootfs/usr/lib/tmpfiles.d/nscd.conf
