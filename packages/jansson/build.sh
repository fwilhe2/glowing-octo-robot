# Autotools, one .so, no optional dependencies. --disable-static for the same reason as
# libmnl: the trim deletes *.a anyway, and not building it is cheaper.
./configure --prefix=/usr --disable-static
make
make install DESTDIR=$ROOTFS
