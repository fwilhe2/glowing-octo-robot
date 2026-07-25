export FORCE_UNSAFE_CONFIGURE=1

# --without-selinux: the builder image has libselinux-dev (Debian enables SELinux
# support in its coreutils), so configure would otherwise link ls, cp, mv, id and 11
# other core binaries against libselinux.so.1 — a library we don't ship, leaving them
# unrunnable in the image. We have no SELinux policy, so the support is dead weight.
./configure --prefix=/usr --without-selinux
make
make install DESTDIR=/usr/local/rootfs
