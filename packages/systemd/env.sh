VERSION="261.2"
PACKAGE="systemd-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
SHA256="ed1059ff964f5df35b6056434cc17cc83f86dc913f10489948a0b19b6081c5ec"
# build-dep doesn't pull libcap-dev, which systemd's meson requires (sys/capability.h).
UPSTREAM_GITHUB="systemd/systemd"
