# The node agent and its tools: kubelet, kubeadm and kubectl. Go, with every module
# vendored in the repository, so the tag's archive builds with --network=none as it is.
# Not part of the image: EXTENSION puts it in the kubernetes system extension
# (docs/sysext.md), which is where software goes that only a Kubernetes node wants.
VERSION="1.37.1"
PACKAGE="kubernetes-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/kubernetes/kubernetes/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="89295ac375eb0fdfe68a0696d81be615771d6b27c7ad9bb675dc6ffd0d2ce5f3"
LICENSE="Apache-2.0"
EXTENSION=kubernetes
UPSTREAM_GITHUB="kubernetes/kubernetes"
UPSTREAM_SED='s/^v//'
