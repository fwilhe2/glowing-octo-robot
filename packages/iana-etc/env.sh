# The version is the date IANA's registries were snapshotted, not a release number.
# tools/upstream.sh handles it without help: it keeps candidates matching ^[0-9]+(\.[0-9]+)*$,
# which a bare date satisfies, and sort -V orders them correctly.
VERSION="20260723"
PACKAGE="iana-etc-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/Mic92/iana-etc/releases/download/${VERSION}/${TARBALL}"
SHA256="250a2ecd0e6e49e4f9cc31057d7f1119beeb9e459c50dd433966194e9a0a0ce0"
LICENSE="LicenseRef-IANA"
UPSTREAM_GITHUB="Mic92/iana-etc"
