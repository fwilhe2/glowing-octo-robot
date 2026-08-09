#!/usr/bin/env bash
# Load the OCI image and run it:
#
#     ./test/oci.sh [output/flfs-oci.tar]
#
# `podman load` succeeding is already half the test — the archive image/build-rootfs.sh
# writes is a hand-assembled OCI layout, so anything wrong with a media type, a digest or
# the index would fail here rather than at whatever registry it is pushed to later.
#
# The other half is running it, which is cheap in a way the disk image never is: no qemu,
# no boot, a second or two. It is also a weaker check by construction — the container runs
# on the *host's* kernel, so this says nothing about packages/kernel and cannot replace
# test/boot.sh. What it does prove is that the userspace we ship starts: the loader
# resolves, our glibc runs binaries compiled against it, and the entrypoint is a shell.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE="${1:-output/flfs-oci.tar}"

[ -f "$ARCHIVE" ] || {
    echo "error: no OCI archive at $ARCHIVE" >&2
    echo "       build it with: podman run --volume \"\$PWD\"/rootfs:/usr/local/src \\" >&2
    echo "         --volume \"\$PWD\"/output:/usr/local/output rootfs-builder \\" >&2
    echo "         /usr/local/bin/build-rootfs.sh oci" >&2
    exit 1
}

# "Loaded image: localhost/flfs:latest" — the tag comes from the ref.name annotation the
# layout carries, so read it back rather than assuming it.
loaded=$(podman load --quiet --input "$ARCHIVE" | tail -n1)
ref=${loaded##*: }
[ -n "$ref" ] || { echo "error: could not tell what podman loaded: $loaded" >&2; exit 1; }
echo "loaded $ref"

# Everything below runs inside the image, with nothing but bash builtins and coreutils —
# that is all a base image has, and asking for more is how a test starts depending on the
# host. --network=none because none of it needs a network, and an image that quietly did
# would be worth finding out about.
podman run --rm --network=none "$ref" -c '
set -u
fail=0
check() {  # check <description> <test...>
    if "${@:2}"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1"
        fail=1
    fi
}

# os-release gets read the way os-release is meant to be read, rather than with grep —
# which is in the image now, but sourcing a file of shell assignments needs no tool at
# all. Pre-set ID so a missing file is one failed check below rather than an unbound
# variable that kills the script.
ID=
. /etc/os-release 2>/dev/null || true

echo "the shell the entrypoint started:"
check "bash is running as the entrypoint"    test -n "$BASH_VERSION"
check "it started in the configured WORKDIR" test "$PWD" = /root
check "PATH finds our binaries"              test "$(command -v ls)" = /usr/bin/ls
check "os-release identifies the image"      test "$ID" = flfs

echo "what a container must not be carrying:"
check "no kernel"                            test ! -e /boot
check "no systemd"                           test ! -e /usr/lib/systemd
check "no systemctl"                         test ! -e /usr/bin/systemctl
check "no udev"                              test ! -e /usr/lib/udev
check "no units left behind in /etc"         test ! -e /etc/systemd
check "no fstab for a root it never mounts"  test ! -e /etc/fstab
check "no password hashes"                   test ! -e /etc/shadow

# Running these rather than testing -x is the point: a binary whose libraries are not in
# the image is executable right up until it is executed. check-rootfs-deps.sh catches
# that on the staging tree, but only this catches a library the subtraction above took
# away — bash is proven by the fact that anything here ran at all.
echo "and what it must be:"
check "coreutils that start"                 test "$(ls -d /usr)" = /usr
check "and can read the passwd file"         test "$(id -un)" = root
check "the loader has a cache to read"       test -s /etc/ld.so.cache

# Not an assertion — it is the one binary of ours that exists to be looked at, and this
# is the cheapest place in CI that runs a shipped binary at all.
echo
flfsfetch || echo "(flfsfetch is not in this image)"

exit $fail
'
