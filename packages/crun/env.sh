VERSION="1.28"
PACKAGE="crun-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
# The release asset, not the git archive: it ships a generated ./configure and the ~78
# pre-generated libocispec parser sources, so nothing has to run autogen.sh.
URL="https://github.com/containers/crun/releases/download/${VERSION}/${TARBALL}"
# Debian's crun build-deps install libseccomp-dev, libcriu-dev and libprotobuf-c-dev,
# and crun's configure autodetects every one of them — which is the "linked against a
# library only the builder image has" trap. List what this build actually links.
BUILD_DEP=""
EXTRA_DEPS="libcap-dev libjson-c-dev libsystemd-dev python3 pkgconf libtool"
UPSTREAM_GITHUB="containers/crun"
