# shadow-utils, for two of its programs: newuidmap and newgidmap, which write a process's
# user namespace ID maps from the ranges in /etc/subuid and /etc/subgid. That is the one
# privileged step rootless containers need — an unprivileged process may only map its
# own ID — and every rootless engine calls these two to take it. Nothing else of shadow
# ships; accounts here are /etc/passwd and systemd-sysusers.
VERSION="4.20.3"
PACKAGE="shadow-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://github.com/shadow-maint/shadow/releases/download/${VERSION}/${TARBALL}"
SHA256="623be9429f64fa2165bfc5957c6a642ec309c5cf23c0d53855c99f7591922297"
LICENSE="BSD-3-Clause"
UPSTREAM_GITHUB="shadow-maint/shadow"
# Tags from before the 4.x numbering are dates (20001016); they are not releases.
UPSTREAM_IGNORE='^[0-9]{8}$'
