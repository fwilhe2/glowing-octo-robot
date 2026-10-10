# Every optional dependency is turned off by name, the deps.txt discipline:
#
#   --with-mini-gmp     nft needs bignum arithmetic for prefixes and ranges; upstream
#                       bundles a minimal GMP for exactly the case of not wanting libgmp
#   --without-cli       the interactive `nft -i` shell, which wants readline, editline or
#                       linenoise. Scripts and `nft -f` are the way a ruleset is loaded
#   --without-json      `nft -j`, which wants jansson. nspawn speaks the text syntax
#   --without-xtables   translating iptables matches nft does not know natively, which
#                       wants libxtables — an iptables library this image does not have
#   --disable-python    the Python bindings, which would be an interpreter-shaped file
#                       in the image whether or not python were here (constraint 5)
#   --disable-man-doc   building the man pages wants asciidoc, and the trim drops them
./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static \
    --with-mini-gmp \
    --without-cli \
    --without-json \
    --without-xtables \
    --disable-python \
    --disable-man-doc
make
make install DESTDIR=$ROOTFS

# The example rulesets under share/nftables are plain nft syntax with no shebang, so
# nothing interpreted ships. nftables.service is not part of upstream's make install, and
# nothing here loads a ruleset at boot: whoever owns a piece of the firewall (nspawn, for
# its bridge) writes its own table.

# Same as packages/libnftnl: a libtool archive nobody links statically against.
rm -f "$ROOTFS/usr/lib/libnftables.la"
