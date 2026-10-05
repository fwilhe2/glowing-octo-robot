VERSION="2.9.0"
PACKAGE="expat-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
# Release assets on GitHub, filed under a tag that spells the version with underscores.
URL="https://github.com/libexpat/libexpat/releases/download/R_${VERSION//./_}/${TARBALL}"
SHA256="1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051"
LICENSE="MIT"
UPSTREAM_GITHUB="libexpat/libexpat"
# ...and those tags are what the version check sees, so undo the spelling: R_2_8_2.
UPSTREAM_SED='s/^R_//; s/_/./g'
