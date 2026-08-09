# --without-selinux: `tar --selinux` stores and restores security contexts through
# libselinux. There is no policy in the image and libselinux-dev is in deps.txt's
# deliberately-absent list, so this is pinned rather than left to autodetection — the
# same reason coreutils, sed and findutils pin it. Worth pinning here in particular:
# libselinux.so.1 is already on test/known-missing-libs.txt for glibc's nscd, so a tar
# that picked it up would be filed under the accepted backlog and the build would pass.
#
# --with-rmt: rmt is the remote-tape server tar execs for an archive named `host:file`,
# reached over rsh. This image has no rsh, no ssh and no tape drive, so the included
# copy is a binary nothing can start. The option means "use this one, do not build
# ours"; the path is where the default install would have put it, which also keeps
# /usr/libexec from being created for a single dead file — nothing else in the image
# uses that directory. It takes doc/rmt.8 out of the install with it.
#
# ACLs and extended attributes are left on, and they are half the reason tar is here:
# an OCI layer carries file capabilities as `security.capability` xattrs, and
# `tar --xattrs --acls` is what preserves them through an unpack
# (docs/container-runtime.md). libacl1-dev and libattr1-dev are both in
# builder/deps.txt and both libraries are packages we ship.
./configure --prefix=/usr --without-selinux --with-rmt=/usr/libexec/rmt

# ...and the assertion that "left on" actually happened. Neither feature has an option
# that fails the configure when it cannot be had: `--with-posix-acls` and `--with-xattrs`
# check for the headers and quietly turn themselves back off, so asking for them
# explicitly would prove nothing. Nor would readelf — the ACL half links libacl, but the
# xattr syscall wrappers are in glibc, so a tar with no xattr support has exactly the
# same NEEDED as one with it. config.h is where the answer actually is.
#
# The failure this catches is silent in the worst way: a tar built without these unpacks
# a layer with no error and no capabilities, and the container it produces is subtly
# wrong rather than broken.
for feature in HAVE_POSIX_ACLS HAVE_XATTRS; do
    if ! grep -q "^#define $feature" config.h; then
        echo "error: tar configured without $feature — see builder/deps.txt" >&2
        exit 1
    fi
done

make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs
