#!/bin/bash
# Container entrypoint shared by every package builder. Prepares the rootfs staging
# tree, then runs the package's own build commands.
#
# Bind mounts set up by ../build.sh:
#   /usr/local/src      unpacked source tree (working directory)
#   /package-build.sh   the package's build.sh
#   /usr/local/rootfs   staging tree all packages install into (DESTDIR)
#   /usr/local/sysroot  tree with our glibc in it, compiled against as $SYSROOT
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# Compile and link against our own glibc instead of the builder image's (issue #33).
# Without this the shipped binaries carry GLIBC_x.y symbol requirements from whatever
# glibc sid happens to have today, while the image ships ours — it only works as long
# as the two stay close enough, and breaks silently when they drift apart.
#
# This is the interim fix, not a staged LFS toolchain: --sysroot redirects the *default*
# header and library paths at our glibc, and the builder image's own directories are put
# back afterwards (-idirafter, trailing -L) so everything else a package needs to link
# against — kernel headers, and the optional libraries we haven't packaged yet — is
# still found there. So glibc comes from us, the rest is still Debian's.
if [ -n "${SYSROOT:-}" ]; then
    multiarch=$(gcc -print-multiarch)

    sysroot_cppflags="--sysroot=$SYSROOT"
    sysroot_cppflags+=" -idirafter /usr/include/$multiarch -idirafter /usr/include"

    # glibc splits itself across two directories: the shared objects go to slibdir
    # (/lib64, which the merged-/usr staging above points at /usr/lib) and the files
    # only the linker ever reads — libc.so, crt1.o and friends — go to libdir,
    # /usr/lib64. Both have to be named explicitly, and ahead of the builder image's
    # directories at the end: an explicit -L outranks the sysroot's own defaults, so
    # putting Debian's back without naming ours first hands -lc straight back to sid.
    #
    # -B, not just -L, for the crt files: gcc looks for those in its own startfile
    # directories, which are relative to where gcc is installed and so never sysrooted.
    # Without it a package links Debian's Scrt1.o against our libc. -rpath-link is
    # link-time only — it resolves the dependencies of the libraries being linked
    # against without baking a builder path into the binary.
    sysroot_ldflags="--sysroot=$SYSROOT"
    for dir in /usr/lib64 /usr/lib; do
        [ -d "$SYSROOT$dir" ] || continue
        sysroot_ldflags+=" -B$SYSROOT$dir -L$SYSROOT$dir -Wl,-rpath-link,$SYSROOT$dir"
    done
    sysroot_ldflags+=" -L/usr/lib/$multiarch -L/usr/lib"
    # ...and -rpath-link for them as well, not just -L. A -L only resolves libraries the
    # link names itself; the libraries those in turn need — libpam.so needing
    # libaudit.so.1 — are looked up in the linker's default directories, which --sysroot
    # has just moved into our tree, where Debian's dependencies aren't.
    sysroot_ldflags+=" -Wl,-rpath-link,/usr/lib/$multiarch -Wl,-rpath-link,/usr/lib"

    export CPPFLAGS="$sysroot_cppflags${CPPFLAGS:+ $CPPFLAGS}"
    export CFLAGS="$sysroot_cppflags${CFLAGS:+ $CFLAGS}"
    export CXXFLAGS="$sysroot_cppflags${CXXFLAGS:+ $CXXFLAGS}"
    export LDFLAGS="$sysroot_ldflags${LDFLAGS:+ $LDFLAGS}"
fi

cd /usr/local/src
source /package-build.sh
