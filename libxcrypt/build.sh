# --enable-obsolete-api=glibc builds libcrypt.so.1 with the glibc-compatible ABI that
# systemd (linked against Debian's libcrypt) expects. glibc 2.42 no longer ships it.
#
# --disable-werror: since we compile against our own glibc rather than the builder's,
# string.h is 2.44's, where strchr is type-preserving as C23 requires — it hands back a
# const char * for a const char * argument. crypt-gost-yescrypt.c assigns that straight
# to a char *, which -Werror=discarded-qualifiers makes fatal. Upstream's warning to
# fix, not ours to patch around.
./configure --prefix=/usr --enable-obsolete-api=glibc --disable-failure-tokens \
  --disable-werror
make
make install DESTDIR=/usr/local/rootfs
