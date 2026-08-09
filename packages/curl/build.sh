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
#
# The `--disable-` block below is the protocol list. A default build speaks twenty-four
# schemes; this image wants three. HTTP and HTTPS are why curl is here at all
# (constraint 4, and every registry API in docs/container-runtime.md), and FILE stays
# because it costs 17 KB of source, opens no socket and parses nothing an attacker
# controls — it is the one entry here that is not really a protocol. Everything else is
# a mail, terminal, media or gateway client with no caller in the image: nothing here
# reads mail (imap, pop3, smtp), logs in over cleartext (telnet), boots over the network
# (tftp), streams video (rtsp), talks to a broker (mqtt) or resolves a content hash
# (ipfs, ipns — which are only a rewrite onto an HTTP gateway anyway). SMB was never on,
# and gopher and dict are here because curl is thirty years old.
#
# ws/wss is the one worth pausing over, because Kubernetes uses WebSockets for exec and
# attach — but that is kubectl's and the kubelet's business, not a shell client's, and
# neither is curl.
#
# FTP is the largest single removal (ftp.c plus ftplistparser.c is 172 KB of source,
# more than a quarter of everything dropped here). It is also the one with a real
# argument for it — tarball mirrors still speak it — but that is the *builder's* problem
# and the builder uses Debian's curl, not this one.
#
# Then the authentication schemes, on the same test. NTLM is Windows domains; kerberos
# and negotiate need a GSSAPI library that is neither in deps.txt nor in the image, so
# they were already off and are now off by name rather than by luck (same discipline as
# the --without- list above); aws-sigv4 signs requests to a cloud API nothing here
# calls. Basic, digest and bearer stay — those are what a registry actually asks for.
#
# --disable-tls-srp has a second reason beyond being unused. SRP is password-based TLS
# authentication that essentially nothing deploys, and it is the only thing making
# libcurl reference SSL_CTX_set_srp_username/_password. Because CI builds each package
# against a glibc-only sysroot, curl compiles against the *builder image's* libssl-dev
# headers and only meets our libcrypto/libssl at runtime — so an `no-srp` added to
# packages/openssl/build.sh while curl still wanted those symbols would produce a curl
# that fails to start, and nothing in test/ would catch it before qemu. Dropping the
# consumer first is what makes trimming OpenSSL safe later.
#
# --disable-alt-svc: Alt-Svc is how a server advertises an HTTP/2 or HTTP/3 endpoint,
# and --without-nghttp2/nghttp3/ngtcp2 above means there is nothing to upgrade to.
# --disable-doh: DNS-over-HTTPS is a second resolver inside curl, and DNS here is
# systemd-resolved end to end (constraint 4). HSTS and netrc deliberately stay — the
# first is security-positive and the second is how a registry credential gets supplied.
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

make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs

# curl-config exists to tell a compiler where libcurl's headers and libraries are, and
# there is no compiler in the image and no headers either — the trim deletes them. That
# was always the load-bearing half of this deletion; the other half, that its #!/bin/sh
# had no interpreter here, stopped being true when packages/bash/build.sh linked sh.
rm -f /usr/local/rootfs/usr/bin/curl-config
