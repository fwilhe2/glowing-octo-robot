VERSION="1.7.0"
PACKAGE="libbpf-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/libbpf/libbpf/archive/refs/tags/${TARBALL}"
SHA256="7ab5feffbf78557f626f2e3e3204788528394494715a30fc2070fcddc2051b7b"
LICENSE="LGPL-2.1-only OR BSD-2-Clause"
# Debian's source package is libbpf, but its build-deps drag in the whole kernel BPF
# toolchain (clang, llvm, bpftool) that only the selftests need. The library itself
# needs libelf and zlib headers and nothing else.
UPSTREAM_GITHUB="libbpf/libbpf"
