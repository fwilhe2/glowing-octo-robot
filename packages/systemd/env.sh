VERSION="262"
PACKAGE="systemd-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
SHA256="6aa77506c0644aa67f940a48e3d3a7368601f787e4f249139516d353f107bcab"
LICENSE="LGPL-2.1-or-later AND GPL-2.0-or-later"
# build-dep doesn't pull libcap-dev, which systemd's meson requires (sys/capability.h).
UPSTREAM_GITHUB="systemd/systemd"
