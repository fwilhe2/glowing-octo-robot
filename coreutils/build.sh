export FORCE_UNSAFE_CONFIGURE=1

./configure --prefix=/usr
make
make install DESTDIR=/usr/local/rootfs
