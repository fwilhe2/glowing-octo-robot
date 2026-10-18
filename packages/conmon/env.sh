# The container monitor: one small process per container that holds its stdio and exit
# status while podman itself is not running — which is what makes podman daemonless.
# C, on glib.
VERSION="2.2.1"
PACKAGE="conmon-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/containers/conmon/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="814fb5979a3a4b8576b1f901e606b482bebb41cb7e57926e6d5765ee786b96d3"
LICENSE="Apache-2.0"
UPSTREAM_GITHUB="containers/conmon"
UPSTREAM_SED='s/^v//'
