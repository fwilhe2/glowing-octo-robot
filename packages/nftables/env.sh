# `nft`, the userspace half of nf_tables. The kernel side has been in container.config
# since containers were (constraint 3: netfilter/nftables is in scope and must not be
# configured away), but until now nothing in the image could load a ruleset into it.
# nspawn is what asked: it manages its nspawn0 bridge's NAT and forwarding with nft.
#
# nftables rather than iptables, and not as a matter of taste: iptables-nft is a
# compatibility layer that translates into nf_tables anyway, iptables-legacy is the
# xtables path the kernel config does not build, and every current distribution's
# firewall (firewalld, Debian's default ruleset) and container network stack is written
# against nft. nspawn calls iptables too, but only to ask whether Docker's FORWARD policy
# is in the way, and treats a missing iptables as "no".
VERSION="1.1.7"
PACKAGE="nftables-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://www.netfilter.org/pub/nftables/${TARBALL}"
SHA256="a6fbf060d8d4fff001517a2b94f356bb4366bfbf0ba366366f9d27cc38caa58f"
LICENSE="GPL-2.0-only"
