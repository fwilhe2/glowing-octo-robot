# Three protocols (HTTP, HTTPS, FILE), the auth schemes a registry asks for (basic,
# digest, bearer), zlib and zstd. Everything else is named off: none of those libraries
# are in the builder today, and naming them keeps a later line in builder/deps.txt from
# pulling one into curl. No HTTP/2 until a registry client needs it (nghttp2).
#
# --with-ca-bundle is packages/ca-certificates' file. --without-ca-path, or configure
# would guess from the builder's own /etc/ssl (and a hashed CApath needs c_rehash, perl).
# --disable-tls-srp: the only reason libcurl references OpenSSL's SRP symbols, so OpenSSL
# can be built without them. HSTS and netrc stay.
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
    --disable-manual \
    --disable-dict \
    --disable-ftp \
    --disable-gopher \
    --disable-imap \
    --disable-ipfs \
    --disable-mqtt \
    --disable-pop3 \
    --disable-rtsp \
    --disable-smb \
    --disable-smtp \
    --disable-telnet \
    --disable-tftp \
    --disable-websockets \
    --disable-ntlm \
    --disable-kerberos-auth \
    --disable-negotiate-auth \
    --disable-aws \
    --disable-tls-srp \
    --disable-alt-svc \
    --disable-doh

make
make install DESTDIR=$ROOTFS

# curl-config describes headers the trim deletes.
drop_installed curl-config
