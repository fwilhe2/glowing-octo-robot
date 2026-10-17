VERSION="262.1"
PACKAGE="systemd-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
SHA256="100fc873b848b9b0297d8a705e8e2ed326256c8483d9960ee1ffe264c8a5c3e3"
LICENSE="LGPL-2.1-or-later AND GPL-2.0-or-later"
# build-dep doesn't pull libcap-dev, which systemd's meson requires (sys/capability.h).
UPSTREAM_GITHUB="systemd/systemd"
