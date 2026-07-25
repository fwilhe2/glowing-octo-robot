VERSION="2.42.2"
PACKAGE="util-linux-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
# kernel.org files tarballs by major.minor series, so 2.42.2 lives in v2.42/.
IFS=. read -r _major _minor _ <<< "$VERSION"
URL="https://www.kernel.org/pub/linux/utils/util-linux/v${_major}.${_minor}/${TARBALL}"
UPSTREAM_INDEX="https://www.kernel.org/pub/linux/utils/util-linux/"
UPSTREAM_SUBDIR="v[0-9]+\.[0-9]+/"
