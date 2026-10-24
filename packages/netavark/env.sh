# podman's network backend: creates the bridge, the veth pairs and the nftables rules
# for each container network, and hands DNS to aardvark-dns. Rust, from the containers
# project like podman and crun; the only backend podman 6 supports.
#
# Two tarballs. The source is the tag's archive, and the crates it depends on come as a
# separate vendor tarball upstream publishes with every release, so the build can run
# with --network=none. Both are pinned; tools/bump-version.sh rewrites both.
VERSION="2.1.0"
PACKAGE="netavark-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/containers/netavark/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="96677048168ddd1abe313e4c2e17f1cace72b60ee1bac8ca12a4bd7dfcadfbbb"
VENDOR_TARBALL="netavark-v${VERSION}-vendor.tar.gz"
VENDOR_URL="https://github.com/containers/netavark/releases/download/v${VERSION}/${VENDOR_TARBALL}"
VENDOR_SHA256="532779573b7f4c2606e43f8471132bb9072417feed9ee06a4e309cf3fa066ab8"
LICENSE="Apache-2.0"
# In the podman system extension, not the image (EXTENSION, see build.sh): the base keeps
# the container runtime — the kernel, crun, conmon — and an engine is loaded on demand
# (docs/sysext.md, #192).
EXTENSION=podman
UPSTREAM_GITHUB="containers/netavark"
UPSTREAM_SED='s/^v//'
