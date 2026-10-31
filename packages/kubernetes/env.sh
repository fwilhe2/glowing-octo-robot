# The node agent and its tools: kubelet, kubeadm and kubectl. Go, with every module
# vendored in the repository, so the tag's archive builds with --network=none as it is.
# Not part of the image: EXTENSION puts it in the kubernetes system extension
# (docs/guides/sysext.md), which is where software goes that only a Kubernetes node wants.
VERSION="1.37.2"
PACKAGE="kubernetes-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/kubernetes/kubernetes/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="6b1a4921ce0249a4607528e2b4f211c6aaeb2f03204bcabefabb3f6742ba67b8"
LICENSE="Apache-2.0"
CPE="cpe:2.3:a:kubernetes:kubernetes:${VERSION}:*:*:*:*:*:*:*"
EXTENSION=kubernetes
UPSTREAM_GITHUB="kubernetes/kubernetes"
UPSTREAM_SED='s/^v//'
