# --enable-obsolete-api=glibc builds libcrypt.so.1 with the glibc-compatible ABI that
# systemd (linked against Debian's libcrypt) expects. glibc 2.42 no longer ships it.
./configure --prefix=/usr --enable-obsolete-api=glibc --disable-failure-tokens
make
make install DESTDIR=/usr/local/rootfs
