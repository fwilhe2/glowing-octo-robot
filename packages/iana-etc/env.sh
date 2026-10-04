# The version is the date IANA's registries were snapshotted, not a release number.
# tools/upstream.sh handles it without help: it keeps candidates matching ^[0-9]+(\.[0-9]+)*$,
# which a bare date satisfies, and sort -V orders them correctly.
VERSION="20260930"
PACKAGE="iana-etc-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/Mic92/iana-etc/releases/download/${VERSION}/${TARBALL}"
SHA256="ead94c150ba26a30a33c36722b97624fd9ff24c80abcd6303a21af52b24f9e55"
LICENSE="LicenseRef-IANA"
UPSTREAM_GITHUB="Mic92/iana-etc"
