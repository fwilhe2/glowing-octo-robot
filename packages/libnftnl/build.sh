# Nothing optional to turn off beyond the static archive: its only dependency is libmnl.
./configure --prefix=/usr --disable-static
make
make install DESTDIR=$ROOTFS

# The libtool archive goes, as Debian removes it. It records libmnl as `/usr/lib/libmnl.la`
# — a path in the staging tree, not in the builder — so libtool in nftables' link, finding
# this file through a sysroot that is the whole of rootfs/ (any local build), follows it
# to a file that does not exist and fails. A .la only matters for static linking, which
# nothing here does, and the image trim deletes every one anyway.
rm -f "$ROOTFS/usr/lib/libnftnl.la"
