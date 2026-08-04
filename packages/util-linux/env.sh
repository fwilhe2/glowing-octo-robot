VERSION="2.42.2"
PACKAGE="util-linux-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
# kernel.org files tarballs by major.minor series, so 2.42.2 lives in v2.42/.
IFS=. read -r _major _minor _ <<< "$VERSION"
URL="https://www.kernel.org/pub/linux/utils/util-linux/v${_major}.${_minor}/${TARBALL}"
SHA256="e73fe91d9b536c6e3548132c1e327843b0bac3c94be9f158ce112eb989d25fc7"
UPSTREAM_INDEX="https://www.kernel.org/pub/linux/utils/util-linux/"
UPSTREAM_SUBDIR="v[0-9]+\.[0-9]+/"
