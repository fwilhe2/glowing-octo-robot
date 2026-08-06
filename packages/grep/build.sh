# --disable-perl-regexp: `grep -P` is implemented by libpcre2-8, which we do not ship.
# libpcre2-dev is not in builder/deps.txt today, so configure would find nothing and
# turn the feature off by itself — which is exactly the problem. Autodetection means the
# binary depends on which -dev packages the builder image happens to carry, and the day
# something else needs libpcre2-dev, grep silently starts linking against a library that
# is not in the image and `grep -P` dies with status 127 in qemu. Pin it, the way
# coreutils pins --without-openssl.
#
# --without-libsigsegv: grep uses it to turn a stack overflow in the matcher into a
# clean error instead of a SIGSEGV. Same reasoning — not in the builder image now,
# pinned so it stays that way.
./configure --prefix=/usr --disable-perl-regexp --without-libsigsegv
make
make install DESTDIR=/usr/local/rootfs
