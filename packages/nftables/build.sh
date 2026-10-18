# --with-json is the reason this package exists: netavark has no other way to drive the
# firewall than `nft -j`, and configure leaves it off by default. It needs jansson, which
# is a package of its own; the check after the install is what makes "configure found
# it" a fact rather than an assumption.
#
# --with-mini-gmp: nft does arbitrary-precision arithmetic on set elements and prefixes,
# and the full libgmp is deliberately absent from the image (builder/deps.txt has it only
# for gcc's cc1). The bundled mini-gmp is upstream's answer for exactly this.
#
# --without-cli: the interactive `nft -i` shell, which wants readline or libedit. Neither
# ships, and nft is a command run with arguments here.
#
# --disable-man-doc: the docs need asciidoc, and the trim deletes man pages anyway.
./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static \
    --disable-debug \
    --disable-man-doc \
    --with-json \
    --with-mini-gmp \
    --without-cli \
    --without-xtables
make
make install DESTDIR=$ROOTFS

# The JSON parser is in libnftables, not in nft itself.
readelf -d $ROOTFS/usr/lib/libnftables.so.1 | grep -q 'libjansson\.so' || {
    echo "nftables: built without JSON support — netavark cannot use this nft" >&2
    exit 1
}

# Example rulesets under /usr/share/nftables, as executable `#!/usr/sbin/nft -f`
# scripts. Not an interpreter in the constraint-5 sense — nft is the program they are
# input to — but a dozen files nothing here runs, and /etc is read-only on the image, so
# nobody can adopt one by copying it either.
rm -rf $ROOTFS/usr/share/nftables
