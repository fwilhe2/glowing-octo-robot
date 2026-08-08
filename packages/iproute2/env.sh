# `ip`, `ss`, `bridge` and `tc`: the userspace half of the kernel's networking, and the
# answer to "what does this machine think its address is" from inside the guest.
# networkctl only queries what networkd was told to configure; nothing in the image
# could look at or change a link, address or route until this.
#
# net-tools (ifconfig/route/netstat) is the alternative and is not a candidate: upstream
# has been in maintenance since 2001, it cannot see anything rtnetlink added after it
# (multiple addresses per interface, policy routing, netns), and every distribution now
# ships it, if at all, as a compatibility shim.
#
# Versions track the kernel's, one release behind at most; 7.1.0 is the pair to the
# 7.1.x in packages/kernel.
VERSION="7.1.0"
PACKAGE="iproute2-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://www.kernel.org/pub/linux/utils/net/iproute2/${TARBALL}"
SHA256="fd9fa1b95809417157ca83dd72957e3261bdbce896353cb936f80af0b33a4b5c"
# COPYING is GPLv2, and most sources say GPL-2.0-or-later; the tc schedulers carry a
# BSD-3-Clause offer alongside the GPL. What the tarball also holds and does not ship is
# netem's table generators, which are NIST public domain: they run at build time and
# emit the /usr/lib/tc/*.dist data, the same way a perl configure never reaches the
# image. rdma/ is `GPL-2.0 OR Linux-OpenIB`, a choice, and this takes the GPL half.
LICENSE="GPL-2.0-only AND GPL-2.0-or-later AND BSD-3-Clause"
