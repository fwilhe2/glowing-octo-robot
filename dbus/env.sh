VERSION="1.16.2"
PACKAGE="dbus-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://dbus.freedesktop.org/releases/dbus/${TARBALL}"
# dbus numbers its development releases with an odd minor (1.15.x, 1.17.x) and files
# them in the same directory as the stable ones, so skip them.
UPSTREAM_IGNORE='[0-9]+\.[0-9]*[13579]\..*'
