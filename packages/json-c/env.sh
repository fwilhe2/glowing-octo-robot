VERSION="0.19"
PACKAGE="json-c-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
# Upstream's own release bucket, byte-identical to the GitHub release asset but named
# after the version alone — the GitHub URL buries a release date in the tag
# (json-c-0.19-20260627/) that a VERSION bump has no way to guess.
URL="https://s3.amazonaws.com/json-c_releases/releases/${TARBALL}"
SHA256="37ad0249902e301bd9052bf712e511fcc6acff4ecaad4b5900aad9ce564e26de"
# Debian's json-c build-deps pull in doxygen and the rest of the documentation
# toolchain for a library that is one .so; cmake is all this build actually needs.
# The bucket answers 403 to a listing, so take versions from the tags instead...
UPSTREAM_GITHUB="json-c/json-c"
# ...which is where that release date shows up again: json-c-0.19-20260627 -> 0.19.
UPSTREAM_SED='s/^json-c-//; s/-[0-9]{8}$//'
