# tcpdump: packets on an interface, as they are. What a container's traffic looks like
# on its veth, on podman's bridge and on the uplink is the one question about netavark,
# pasta or a CNI that their own logs never answer.
#
# libpcap is a second tarball rather than a package of its own, and linked statically.
# An extension's packages compile against the base's staging tree, never against each
# other's (build.sh), so a libpcap package would have to put libpcap in the base for
# every machine to carry — and tcpdump is its only consumer. The tcpdump project
# releases both, from the same site, and documents building them side by side.
VERSION="4.99.7"
PACKAGE="tcpdump-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://www.tcpdump.org/release/${TARBALL}"
SHA256="39675dfa06fb0e99be8da5d4a1784acbaab58ae0870231d956ff7870cb99eec1"
# Its own version, not tcpdump's: tools/bump-version.sh refetches it on a tcpdump bump
# and finds the same bytes, and tools/check-updates.sh does not watch it — a libpcap
# release is a line changed here by hand.
LIBPCAP_VERSION="1.10.7"
VENDOR_TARBALL="libpcap-${LIBPCAP_VERSION}.tar.xz"
VENDOR_URL="https://www.tcpdump.org/release/${VENDOR_TARBALL}"
VENDOR_SHA256="68fa62cffb974f4275641ce14c2e2d75739251f30e00e6a0900903b247d76a03"
LICENSE="BSD-3-Clause"
# In the debug system extension (docs/debugging.md).
EXTENSION=debug
