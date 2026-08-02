# libcap uses a plain Makefile. lib=lib keeps it out of /usr/lib64; PAM_CAP=no avoids
# pulling in a PAM dependency we don't ship.
make prefix=/usr lib=lib GOLANG=no
make install prefix=/usr lib=lib GOLANG=no PAM_CAP=no DESTDIR=/usr/local/rootfs
