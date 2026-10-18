# GLib, for conmon, which is built on its main loop. Only libglib-2.0 ships — see build.sh.
#
# Coupled to the builder's version the way packages/openssl is: consumers compile against
# sid's libglib2.0-dev headers and resolve against this library by SONAME, and glib's
# symbols are unversioned, so a header newer than the library is a missing symbol at
# runtime that test/check-symbol-versions.sh cannot see. Keep this at or above sid's.
#
# The stable series is the even minor; odd minors are development snapshots, which
# UPSTREAM_IGNORE keeps tools/check-updates.sh from proposing.
VERSION="2.90.1"
PACKAGE="glib-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://download.gnome.org/sources/glib/${VERSION%.*}/${TARBALL}"
SHA256="93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396"
LICENSE="LGPL-2.1-or-later"
UPSTREAM_INDEX="https://download.gnome.org/sources/glib/"
UPSTREAM_SUBDIR='2\.[0-9]*[02468]/'
