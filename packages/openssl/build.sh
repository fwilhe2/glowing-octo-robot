# Configure takes no target: with none given it guesses one from uname, which is what we
# want on both of the architectures this builds on natively.
#
#   --libdir=lib      OpenSSL's own default is lib64 on x86_64, which nothing in the
#                     image searches. Same reason the meson packages pass -Dlibdir=lib.
#   --openssldir      where the library looks for its configuration and its default trust
#                     store. /etc/ssl is the path everything else assumes; packages/
#                     ca-certificates puts the bundle there.
#   no-docs           the man pages are pod, rendered by perl at build time, and there is
#                     no man in the image to read them. This also removes the only reason
#                     the build would need pod2man.
#   no-tests          40 MB of test binaries that are never run here.
#   no-legacy         the legacy provider is MD4, DES, RC2, RC4, Blowfish and friends —
#                     algorithms that exist so that OpenSSL can still read files written
#                     in 2005. Nothing in this image reads one, and the default and
#                     default-fips providers are built into libcrypto rather than being
#                     modules, so this leaves usr/lib/ossl-modules with nothing in it.
#   no-weak-ssl-ciphers   not a default, and it should be: RC4 and friends in the TLS
#                     cipher list. A client that only talks to registries and web servers
#                     has no negotiation to lose.
#
# The four `*eng` lines are the four engines a default build installs into
# usr/lib/engines-3, and each is dead here by the same test the image trim uses —
# nothing in the image can reach it, not merely nothing is likely to:
#
#   afalgeng     talks to the kernel's crypto sockets, and vm.config builds no
#                CRYPTO_USER_API
#   padlockeng   the VIA C3/C7 crypto instructions, on a CPU no VM here presents
#   capieng      Windows CryptoAPI
#   loadereng    the OSSL_STORE loader for file formats no-legacy has already dropped
#
# The ENGINE API itself stays (there is a `no-engine`, and this does not use it): curl's
# configure looks for it, and building without it is a difference from every other
# distribution's OpenSSL for no gain.
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

make -j"$(nproc)"

# install_sw is the libraries, the openssl binary and the headers; install_ssldirs is
# /etc/ssl and the two configuration files that live in it. The plain `install` target is
# those two plus install_docs, which no-docs has already made empty — naming the two says
# what is wanted rather than relying on that.
make install_sw install_ssldirs DESTDIR=/usr/local/rootfs

# The perl that does survive `make install`, and the only place CLAUDE.md's constraint 5
# actually bites this package: c_rehash builds the hashed symlink farm in a CApath
# directory, and CA.pl/tsget are demo scripts. All three are #!/usr/bin/perl and the
# image has no perl, so they would ship as files that cannot run. Nothing needs them —
# the trust store here is a single concatenated bundle, not a CApath, so there is
# nothing to rehash.
rm -f  /usr/local/rootfs/usr/bin/c_rehash
rm -rf /usr/local/rootfs/etc/ssl/misc

# install_ssldirs writes each configuration file twice — openssl.cnf and openssl.cnf.dist,
# the second being the pristine copy so that an upgrade can tell whether the first was
# edited. There is no upgrade here: the image is rebuilt from source every time and
# nothing edits /etc/ssl in place, so the second copy is 13 KB of the same bytes.
rm -f /usr/local/rootfs/etc/ssl/*.dist

# ...and the two module directories the install creates whether or not anything goes in
# them, which after the options above is both of them. An empty engines-3 next to four
# `no-*eng` flags reads as something having gone wrong; it has not.
rmdir /usr/local/rootfs/usr/lib/engines-3 /usr/local/rootfs/usr/lib/ossl-modules 2>/dev/null || true
