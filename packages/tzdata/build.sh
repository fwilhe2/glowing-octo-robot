# /usr/share/zoneinfo, compiled from IANA's sources by their own zic. Nothing here read
# it before: Go's time.LoadLocation fails without it, and so does glibc's localtime()
# for any TZ that is not UTC. The image keeps no /etc/localtime, which glibc, Go and
# systemd all read as UTC; `timedatectl set-timezone` creates the link when someone wants
# another.
#
# glibc no longer installs zic, so this builds one. It is compiled by the builder's gcc
# against our glibc like everything else, runs in this container, and is not shipped —
# nor is zdump, nor tzselect, which is a ksh script.
#
#   -b slim          omit the 32-bit data and the transitions a TZif v2+ reader derives
#                    from the trailing TZ string anyway. glibc and Go both read slim
#                    files; it is zic's default, said here so it stays that way.
#   REDO=posix_only  no right/ (leap-second-counting) tree beside the posix one, which
#                    would double the size for a clock convention nothing here uses.
#   VERSION          the git tree has no `version` file and the Makefile would otherwise
#                    ask git, which is not there.
#
# The install goes to a scratch DESTDIR because it also writes usr/etc/localtime, and
# TOPDIR cannot be split so that one lands somewhere harmless. Only zoneinfo is copied
# out of it.
stage=$(mktemp -d)
make CC=gcc CFLAGS="-O2 $CFLAGS" LDFLAGS="$LDFLAGS" \
    VERSION="$FLFS_VERSION" TOPDIR=/usr TZDIR=/usr/share/zoneinfo \
    ZFLAGS='-b slim' REDO=posix_only DESTDIR="$stage" \
    install

test -f "$stage/usr/share/zoneinfo/Europe/Berlin"
mkdir -p "$ROOTFS/usr/share"
cp -a "$stage/usr/share/zoneinfo" "$ROOTFS/usr/share/"
rm -rf "$stage"
