# The image's TLS. Nothing here could open an HTTPS connection before it.
#
# docs/container-runtime.md preferred mbedTLS on size — ~1.5 MB against OpenSSL's ~5 —
# and issue #77 left the choice open. It is settled the other way, on the "modern *and*
# established" test in CLAUDE.md. mbedTLS is established in embedded firmware; OpenSSL is
# what a general-purpose Linux has, and this image is meant to be one: Debian, Fedora and
# Alpine all ship it as *the* TLS library, and the next thing here that wants TLS —
# openssh is the obvious candidate — will look for libcrypto and find it. Carrying both
# is the outcome nobody wants, so the one to carry is the one that scales. It is modern
# too: 3.5 does TLS 1.3 and ML-KEM key exchange, and its Configure being perl was never
# a disqualification — see the rule in docs/container-runtime.md.
#
# Two reasons this pins the 3.5 LTS branch rather than tracking whatever is newest, and
# only the second is negotiable:
#
#   - The SONAME has to agree with the builder image's headers. curl is compiled against
#     Debian sid's libssl-dev (3.6.x today), so its NEEDED says libcrypto.so.3 and
#     libssl.so.3, and it is our library that answers at runtime. OpenSSL 4.x is
#     libcrypto.so.4 — taking it before sid does would fail test/check-rootfs-deps.sh,
#     and taking it silently is what an unbounded version check would do.
#   - 3.5 is supported to 2030; a non-LTS branch gets about a year. For the one library
#     here whose bugs are remotely exploitable, that is worth staying on.
#
# Being *behind* sid is safe in a way being ahead of it is not: the version nodes a
# binary asks for are the ones its library defined at link time, and curl uses nothing
# newer than OPENSSL_3.0.0. test/check-symbol-versions.sh is what would say otherwise.
VERSION="3.5.7"
PACKAGE="openssl-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/openssl/openssl/releases/download/${PACKAGE}/${TARBALL}"
SHA256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
LICENSE="Apache-2.0"
UPSTREAM_GITHUB="openssl/openssl"
# Tags are openssl-3.5.7; the ancient ones are OpenSSL_1_1_1w and never survive the
# numeric filter in tools/upstream.sh.
UPSTREAM_SED='s/^openssl-//'
# Everything whose first two components are not 3.5 — later minors, later majors, and
# the older branches that are still getting releases. See the two reasons above; this is
# the line to edit when Debian sid moves to a new SONAME.
UPSTREAM_IGNORE='(3\.[0-46-9]|3\.[0-9]{2}|[0-24-9]|[0-9]{2})\..*'
