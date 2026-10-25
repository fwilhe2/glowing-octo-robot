# The version is the date IANA's registries were snapshotted, not a release number.
# tools/upstream.sh handles it without help: it keeps candidates matching ^[0-9]+(\.[0-9]+)*$,
# which a bare date satisfies, and sort -V orders them correctly.
VERSION="20261022"
PACKAGE="iana-etc-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/Mic92/iana-etc/releases/download/${VERSION}/${TARBALL}"
SHA256="8ea9429c691634056ad8c292cf94df8e4cc5e828dceef658490bcbab132dee7c"
LICENSE="LicenseRef-IANA"
UPSTREAM_GITHUB="Mic92/iana-etc"
