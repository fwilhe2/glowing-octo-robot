VERSION="1.29.1"
PACKAGE="crun-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
# The release asset, not the git archive: it ships a generated ./configure and the ~78
# pre-generated libocispec parser sources, so nothing has to run autogen.sh.
URL="https://github.com/containers/crun/releases/download/${VERSION}/${TARBALL}"
SHA256="b6be9fd9613efe5df414c568ddfaf09857c72ec17a00999f15c132a3d9e120fd"
LICENSE="GPL-2.0-or-later AND LGPL-2.1-or-later"
# Debian's crun build-deps install libseccomp-dev, libcriu-dev and libprotobuf-c-dev,
# and crun's configure autodetects every one of them — which is the "linked against a
# library only the builder image has" trap. List what this build actually links.
UPSTREAM_GITHUB="containers/crun"
