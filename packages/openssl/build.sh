# --libdir=lib: OpenSSL defaults to lib64 on x86_64. --openssldir=/etc/ssl: where the
# configuration and the CA bundle (packages/ca-certificates) are.
# no-legacy: MD4, DES, RC4 and friends; the default providers are built into libcrypto.
# The four engines: kernel crypto sockets the kernel does not build, VIA PadLock, Windows
# CryptoAPI, and loaders for formats no-legacy dropped. The ENGINE API itself stays, as
# every distribution has it.
./Configure \
    --prefix=/usr \
    --libdir=lib \
    --openssldir=/etc/ssl \
    shared \
    no-docs \
    no-tests \
    no-legacy \
    no-weak-ssl-ciphers \
    no-afalgeng \
    no-padlockeng \
    no-capieng \
    no-loadereng

make

make install_sw install_ssldirs DESTDIR=$ROOTFS

# Perl (constraint 5): c_rehash, and CA.pl and tsget in misc/. The trust store is one
# bundle, so there is nothing to rehash.
drop_installed c_rehash etc/ssl/misc

# Pristine copies for an upgrade to compare against; there are no upgrades.
rm -f $ROOTFS/etc/ssl/*.dist

# Created whether or not anything goes in them, and after the options above nothing does.
rmdir $ROOTFS/usr/lib/engines-3 $ROOTFS/usr/lib/ossl-modules 2>/dev/null || true
