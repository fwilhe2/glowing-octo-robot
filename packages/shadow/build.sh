# Configured for the two programs it is here for, with every optional library named off:
# PAM, audit, SELinux, ACLs, btrfs, tcb, the sssd hook, libbsd and logind integration —
# the same discipline as openssh's --without list. Subordinate IDs are the point, so they
# are on.
#
# Not --without-nscd, which 4.20.3 cannot compile: its stub takes an int that every
# caller passes a string, which gcc 15 rejects as -Wint-conversion. The hook it stubs out
# runs `nscd -i` after a program edits passwd or group, which neither of these does, and
# it is a fork of a program that is not here rather than a library to link.
#
# Then only lib/ and the two programs are built, rather than `make` and a list of
# deletions: shadow's other thirty-odd programs (useradd, passwd, su, ...) would each be
# a second implementation of something systemd-sysusers or util-linux already does here.
#
# Neither is installed setuid. They need CAP_SETUID and CAP_SETGID respectively, and
# image/build-rootfs.sh gives them exactly that as a file capability — Fedora's choice,
# and the image's rule that nothing is setuid. Setting the capability here would be lost
# anyway: the CI package artifact is a tar without xattrs.
./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --disable-nls \
    --disable-man \
    --disable-logind \
    --enable-subordinate-ids \
    --without-libpam \
    --without-audit \
    --without-selinux \
    --without-acl \
    --without-btrfs \
    --without-tcb \
    --without-skey \
    --without-sssd \
    --without-libbsd \
    --without-su
make -C lib
make -C src newuidmap newgidmap
install -D -m 755 src/newuidmap $ROOTFS/usr/bin/newuidmap
install -D -m 755 src/newgidmap $ROOTFS/usr/bin/newgidmap

# CAP_SETUID and CAP_SETGID, which are what writing another user namespace's ID maps
# takes. Declared rather than set: whichever assembly takes these files applies it
# (image/build-rootfs.sh has why), and nothing here is setuid.
install -d $ROOTFS/usr/share/flfs/capabilities
cat > $ROOTFS/usr/share/flfs/capabilities/shadow <<'CAPS'
usr/bin/newuidmap cap_setuid=ep
usr/bin/newgidmap cap_setgid=ep
CAPS
