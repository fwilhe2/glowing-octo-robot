# libcap uses a plain Makefile. lib=lib keeps it out of /usr/lib64; PAM_CAP=no avoids
# pulling in a PAM dependency we don't ship.
make prefix=/usr lib=lib GOLANG=no
make install prefix=/usr lib=lib GOLANG=no PAM_CAP=no DESTDIR=$ROOTFS

# libpsx is for programs that change credentials across every thread (Go's runtime,
# chiefly). libcap.so does not link it, and nothing here does.
drop_installed usr/lib/libpsx.so usr/lib/libpsx.so.2 usr/lib/libpsx.so.2.78
