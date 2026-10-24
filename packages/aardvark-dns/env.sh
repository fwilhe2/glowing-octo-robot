# The DNS server netavark starts on a container network's bridge, so containers on a
# user-defined network can reach each other by name. Rust, released in lockstep with
# netavark; the same two-tarball shape.
VERSION="2.1.0"
PACKAGE="aardvark-dns-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/containers/aardvark-dns/archive/refs/tags/v${VERSION}.tar.gz"
SHA256="daf871488603e659b0501224cf0731ac317809b1d1701fc061cb4f6ae39a894f"
VENDOR_TARBALL="aardvark-dns-v${VERSION}-vendor.tar.gz"
VENDOR_URL="https://github.com/containers/aardvark-dns/releases/download/v${VERSION}/${VENDOR_TARBALL}"
VENDOR_SHA256="6e6366828d4cd2ccf3cfe07657d8aba083045605696b4f74967c2c8340f51500"
LICENSE="Apache-2.0"
# In the podman system extension, not the image (EXTENSION, see build.sh): the base keeps
# the container runtime — the kernel, crun, conmon — and an engine is loaded on demand
# (docs/sysext.md, #192).
EXTENSION=podman
UPSTREAM_GITHUB="containers/aardvark-dns"
UPSTREAM_SED='s/^v//'
