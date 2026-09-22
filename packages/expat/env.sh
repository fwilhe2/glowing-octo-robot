VERSION="2.8.5"
PACKAGE="expat-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
# Release assets on GitHub, filed under a tag that spells the version with underscores.
URL="https://github.com/libexpat/libexpat/releases/download/R_${VERSION//./_}/${TARBALL}"
SHA256="1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182"
LICENSE="MIT"
UPSTREAM_GITHUB="libexpat/libexpat"
# ...and those tags are what the version check sees, so undo the spelling: R_2_8_2.
UPSTREAM_SED='s/^R_//; s/_/./g'
