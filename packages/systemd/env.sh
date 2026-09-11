VERSION="261.3"
PACKAGE="systemd-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
SHA256="3f8d3d3969af7214bda600930e14c6a24135eb3dce1ba7f1b980b74e6dc15b72"
LICENSE="LGPL-2.1-or-later AND GPL-2.0-or-later"
# build-dep doesn't pull libcap-dev, which systemd's meson requires (sys/capability.h).
UPSTREAM_GITHUB="systemd/systemd"
