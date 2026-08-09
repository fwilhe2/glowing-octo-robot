# The `--without-` list is most of this file, and it is the deps.txt discipline written
# out: none of these libraries are in the builder image, so configure would not find them
# anyway — but curl has more optional dependencies than anything else here, and a future
# line in deps.txt added for some other package would silently put a new .so in curl's
# NEEDED. Naming them is what makes that impossible rather than unlikely.
#
# The two that are *not* off: zlib and zstd are packages, so Content-Encoding works.
#
# HTTP/2 is the one absence worth arguing about, since a registry would use it. It needs
# nghttp2, which is another package for a protocol every server here also speaks over
# HTTP/1.1; when docs/container-runtime.md's pull tier arrives is the time to revisit.
#
# --with-ca-bundle names the file packages/ca-certificates installs, and --without-ca-path
# turns off the CApath probe beside it: that directory form needs the hashed symlinks
# c_rehash builds, and packages/openssl/build.sh deletes c_rehash for having a perl
# shebang. Without both flags configure guesses from the *builder image's* /etc/ssl,
# which is Debian's trust store and not ours.
#
# --disable-manual drops the `curl --manual` text, which is the man page compiled into
# the binary. There is no man in the image, and this is the same 100 KB the trim would
# have removed if it had landed in share/man instead.
./configure \
    --prefix=/usr \
    --disable-static \
    --with-openssl \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
    --without-ca-path \
    --with-zlib \
    --with-zstd \
    --without-brotli \
    --without-libpsl \
    --without-libidn2 \
    --without-nghttp2 \
    --without-nghttp3 \
    --without-ngtcp2 \
    --without-libssh2 \
    --without-librtmp \
    --without-libgsasl \
    --disable-ldap \
    --disable-ldaps \
    --disable-manual

make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs

# curl-config exists to tell a compiler where libcurl's headers and libraries are, and
# there is no compiler in the image and no headers either — the trim deletes them. That
# was always the load-bearing half of this deletion; the other half, that its #!/bin/sh
# had no interpreter here, stopped being true when packages/bash/build.sh linked sh.
rm -f /usr/local/rootfs/usr/bin/curl-config
