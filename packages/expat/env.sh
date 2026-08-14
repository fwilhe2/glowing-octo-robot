VERSION="2.8.3"
PACKAGE="expat-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
# Release assets on GitHub, filed under a tag that spells the version with underscores.
URL="https://github.com/libexpat/libexpat/releases/download/R_${VERSION//./_}/${TARBALL}"
SHA256="f6256df90c906773d344da084402b7d3e4f22ed41b1a59c989098a83d3ea0c85"
LICENSE="MIT"
UPSTREAM_GITHUB="libexpat/libexpat"
# ...and those tags are what the version check sees, so undo the spelling: R_2_8_2.
UPSTREAM_SED='s/^R_//; s/_/./g'
