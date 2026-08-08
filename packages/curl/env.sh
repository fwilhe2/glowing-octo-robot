# The HTTP client, and the reason the TLS stack above it is here. `curl https://...` from
# inside the guest is half of what issue #77 asks for; the other half is `ip`.
#
# There is no second candidate worth listing. wget2 and httpie are the alternatives and
# neither is close: wget2 drags in its own TLS choice plus libpsl and gettext, httpie is
# python. curl is C, it is in every distribution, and it is the client every registry API
# in docs/container-runtime.md is written against.
VERSION="8.21.0"
PACKAGE="curl-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://curl.se/download/${TARBALL}"
SHA256="aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6"
# curl's own license: MIT with the "not to be used in advertising" clause, i.e. the same
# shape as X11. SPDX gives it an identifier of its own because the text is not quite
# either of them.
LICENSE="curl"
