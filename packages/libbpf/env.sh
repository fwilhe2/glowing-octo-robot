VERSION="1.7.0"
PACKAGE="libbpf-${VERSION}"
TARBALL="v${VERSION}.tar.gz"
URL="https://github.com/libbpf/libbpf/archive/refs/tags/${TARBALL}"
# Debian's source package is libbpf, but its build-deps drag in the whole kernel BPF
# toolchain (clang, llvm, bpftool) that only the selftests need. The library itself
# needs libelf and zlib headers and nothing else.
BUILD_DEP=""
EXTRA_DEPS="libelf-dev zlib1g-dev pkgconf"
UPSTREAM_GITHUB="libbpf/libbpf"
