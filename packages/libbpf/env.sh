VERSION="1.8.0"
PACKAGE="libbpf-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/libbpf/libbpf/archive/refs/tags/${TARBALL}"
SHA256="b7a1e685f90f6a63ead0dd85d053694b222975da8d09c1a966041cff6f0055ff"
LICENSE="LGPL-2.1-only OR BSD-2-Clause"
# Debian's source package is libbpf, but its build-deps drag in the whole kernel BPF
# toolchain (clang, llvm, bpftool) that only the selftests need. The library itself
# needs libelf and zlib headers and nothing else.
UPSTREAM_GITHUB="libbpf/libbpf"
