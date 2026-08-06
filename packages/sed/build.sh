# --without-selinux: sed -i preserves the SELinux context of the file it rewrites when
# built with libselinux. There is no policy in the image and libselinux-dev is one of
# the packages builder/deps.txt deliberately does not install, so this is pinned rather
# than left to autodetection — the same reason coreutils pins it.
#
# ACL support is left on: sed -i preserves ACLs through libacl, and acl and attr are
# packages we build and ship.
./configure --prefix=/usr --without-selinux
make
make install DESTDIR=/usr/local/rootfs
