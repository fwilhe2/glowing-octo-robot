# readline is the one library socat would link that the base lacks (libreadline-dev is
# deliberately absent from builder/deps.txt, so this is belt and braces), and libwrap is
# TCP wrappers, which nothing here configures. OpenSSL stays: the base ships it, and
# OPENSSL: addresses are how to talk to a TLS port without curl's HTTP on top.
./configure \
    --prefix=/usr \
    --disable-readline \
    --disable-libwrap
make socat
# Only socat. filan and procan are its file-descriptor and process inspectors, which
# lsfd and /proc already answer; the socat-*.sh helpers are wrappers for setups this
# image has no use for.
install -D -m 755 socat $ROOTFS/usr/bin/socat
