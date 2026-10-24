# libpcap first, from the second tarball (env.sh), as a static library under /tmp that
# only tcpdump's configure sees. Every capture source but Linux's own is off: USB,
# Bluetooth, D-Bus, RDMA and netmap are hardware or services a VM does not have, and
# each is a library that would otherwise be found in the builder and needed at runtime.
pcap=/tmp/libpcap
rm -rf "$pcap"
(
    cd libpcap-*/
    ./configure \
        --prefix="$pcap" \
        --disable-shared \
        --disable-usb \
        --disable-bluetooth \
        --disable-dbus \
        --disable-rdma \
        --disable-netmap \
        --without-libnl \
        --without-dpdk
    make
    make install
)

# tcpdump finds it through pcap-config, which libpcap installed beside itself.
# libcrypto is only for decrypting IPsec ESP, which nothing here would hand it keys for,
# and libcap-ng is for dropping privileges, which -Z already does without it.
PATH="$pcap/bin:$PATH" ./configure \
    --prefix=/usr \
    --without-crypto \
    --without-cap-ng
make
install -D -m 755 tcpdump $ROOTFS/usr/bin/tcpdump
assert_not_linked libpcap usr/bin/tcpdump
