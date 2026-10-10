# The netlink library nft speaks to the kernel's nf_tables through: it builds and parses
# the rule, set and chain messages, on top of libmnl (already here for iproute2). Nothing
# links it but packages/nftables. Upstream is netfilter.org, the same project as the
# kernel side, and every distribution ships it as nft's one hard dependency.
VERSION="1.3.2"
PACKAGE="libnftnl-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://www.netfilter.org/pub/libnftnl/${TARBALL}"
SHA256="c97abc3409f8fa396b4462b2bb7f147a3a47a4ddc97cfa0b2f18890c9cfde8b0"
LICENSE="GPL-2.0-or-later"
