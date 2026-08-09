# The builder container runs as root, and gnulib's mknod probe will not draw a conclusion
# from that: its test program creates a fifo with mknod(2) and returns 99 when geteuid()
# is 0, because root can do it either way and the answer says nothing about whether an
# ordinary user can. Rather than guess, m4/mknod.m4 stops the configure — "you should not
# run configure as root (set FORCE_UNSAFE_CONFIGURE=1 in environment to bypass this
# check)".
#
# This line used to be that bypass, and the bypass is the worse of the two exits: it takes
# the 99 as a *no*, defines MKNOD_FIFO_BUG and compiles in gnulib's replacement mknod — a
# workaround for a BSD bug, on glibc, which does not have it. Nothing was broken by that,
# which is why it sat here unremarked; it was simply the wrong answer to a question that
# has a right one.
#
# gl_cv_func_mknod_works=yes is not a guess either. It is what the same macro assumes when
# it cannot run the test at all: `linux-*) gl_cv_func_mknod_works="guessing yes"`.
# Presetting the cache variable also means the probe never runs, so rootness never comes
# up, and if a future gnulib renames it the build fails loudly rather than silently
# reverting.
#
# packages/tar/build.sh carries the identical line — it is the same gnulib macro in both,
# differing only in its comments — and says this at greater length, tar having been where
# the check actually failed a build.
export gl_cv_func_mknod_works=yes

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
