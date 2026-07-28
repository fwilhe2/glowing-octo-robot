# Here for dbus, which parses its bus configuration with it. Nothing needs the xmlwf
# tool, the examples or the test suite, and the docs would want docbook2x.
./configure --prefix=/usr --without-docbook --without-examples --without-tests
make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs
