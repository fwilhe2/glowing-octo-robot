# passt/pasta: user-mode networking. pasta is how a rootless podman container reaches the
# network — an unprivileged user cannot create the veth pair and bridge netavark uses for
# root — by translating the container's traffic into ordinary sockets in the user's own
# namespace. Podman's default rootless network since 5.0, replacing slirp4netns. C, no
# dependencies, a seccomp filter of its own.
#
# Releases are date-and-commit tags with no tarballs; the source is the git web
# interface's snapshot of the tag, which is what Debian packages too, and which came
# back byte-identical on repeated downloads when this was pinned.
VERSION="2026_10_02.cba3570"
PACKAGE="passt-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://passt.top/passt/snapshot/${TARBALL}"
SHA256="aa75616cc43925f0bd6c05bcfbbaecd77397c03d7bd23591b34ef535be5dfcdc"
LICENSE="GPL-2.0-or-later AND BSD-3-Clause"
# In the podman system extension, not the image (EXTENSION, see build.sh): the base keeps
# the container runtime — the kernel, crun, conmon — and an engine is loaded on demand
# (docs/sysext.md, #192).
EXTENSION=podman
UPSTREAM_INDEX="https://passt.top/passt/refs/tags"
UPSTREAM_REGEX='passt-([0-9]{4}_[0-9]{2}_[0-9]{2}\.[0-9a-f]{7})\.tar'
UPSTREAM_NUM='[0-9]{4}_[0-9]{2}_[0-9]{2}\.[0-9a-f]{7}'
