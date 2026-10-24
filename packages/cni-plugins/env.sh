# The reference CNI plugins, of which a node needs four: bridge and host-local for a
# single node's pods, loopback for every pod's lo, portmap for hostPort. A cluster's own
# CNI (flannel, Calico) installs its plugin next to these at runtime and delegates to
# them. Static Go, vendored in the repository. In the kubernetes system extension, not
# the image (EXTENSION, see build.sh): netavark, not CNI, is podman's network.
VERSION="1.9.1"
PACKAGE="cni-plugins-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/containernetworking/plugins/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="34bd82d47e981940751619c9cc44c095bb90bfcaf8d71865cbb822c37690a764"
LICENSE="Apache-2.0"
EXTENSION=kubernetes
UPSTREAM_GITHUB="containernetworking/plugins"
UPSTREAM_SED='s/^v//'
