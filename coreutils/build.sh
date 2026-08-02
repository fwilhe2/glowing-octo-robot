export FORCE_UNSAFE_CONFIGURE=1

# --without-selinux: the builder image has libselinux-dev (Debian enables SELinux
# support in its coreutils), so configure would otherwise link ls, cp, mv, id and 11
# other core binaries against libselinux.so.1 — a library we don't ship, leaving them
# unrunnable in the image. We have no SELinux policy, so the support is dead weight.
#
# --without-openssl: same story for libcrypto.so.3. `apt build-dep coreutils` pulls
# libssl-dev into the builder, so cksum/md5sum/sha*sum link against a library the image
# doesn't have and die with status 127. Without it they use coreutils' own hash
# implementations. Pinning this explicitly also stops the build from depending on
# whichever -dev packages happen to be present: configure defaults to auto-detect, so
# the same tree built here and in CI was producing different binaries.
./configure --prefix=/usr --without-selinux --without-openssl
make
make install DESTDIR=/usr/local/rootfs
