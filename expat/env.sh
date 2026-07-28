VERSION="2.8.2"
PACKAGE="expat-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
# Release assets on GitHub, filed under a tag that spells the version with underscores.
URL="https://github.com/libexpat/libexpat/releases/download/R_${VERSION//./_}/${TARBALL}"
UPSTREAM_GITHUB="libexpat/libexpat"
# ...and those tags are what the version check sees, so undo the spelling: R_2_8_2.
UPSTREAM_SED='s/^R_//; s/_/./g'
