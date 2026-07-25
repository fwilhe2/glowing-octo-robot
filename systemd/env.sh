VERSION="258.1"
PACKAGE="systemd-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
# build-dep doesn't pull libcap-dev, which systemd's meson requires (sys/capability.h).
EXTRA_DEPS="libcap-dev"
UPSTREAM_GITHUB="systemd/systemd"
