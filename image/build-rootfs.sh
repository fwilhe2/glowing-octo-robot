#!/bin/bash
set -euo pipefail

set -x

mkdir -p usr/bin bin sbin boot
mkdir -p {dev,etc,home,lib}
mkdir -p {mnt,opt,proc,srv,sys}
mkdir -p var/{lib,lock,log,spool}
install -d -m 0750 root
install -d -m 1777 tmp
mkdir -p usr/{include,lib,share,src}

# systemd checks both of these at startup and tags the system "unmerged-bin" and
# "var-run-bad" in `systemctl show -p Taint` when they are real directories rather than
# symlinks. builder/build-package.sh already stages /usr/sbin as a link, but assert it
# here too: this script is what defines the shipped image, and it should not depend on
# the state the staging tree happened to arrive in.
if [ -d usr/sbin ] && [ ! -L usr/sbin ]; then
    find usr/sbin -mindepth 1 -maxdepth 1 -exec mv -t usr/bin/ {} +
    rmdir usr/sbin
fi
ln -sfn bin usr/sbin

# systemd's own tmpfiles ship `L /var/run - - - - ../run`, but tmpfiles will not replace
# a directory that already exists — so pre-creating var/run above was the only reason the
# link never appeared. Anything staged under it is meaningless anyway: /run is a tmpfs at
# runtime.
if [ -d var/run ] && [ ! -L var/run ]; then
    rm -rf var/run
fi
ln -sfn ../run var/run

cp -r /files/* .

mkdir -p etc/systemd/system
ln -sf /usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

# The kernel execs /sbin/init; point it at systemd.
ln -sf /usr/lib/systemd/systemd sbin/init

# We ship a preconfigured /etc (hostname, root password, locale-less defaults), so the
# interactive first-boot wizard would just block the console waiting for a keypress.
ln -sf /dev/null etc/systemd/system/systemd-firstboot.service

# Binaries carry the ELF interpreter path /lib64/ld-linux-x86-64.so.2 (baked in by
# the toolchain). With merged-/usr, lib64 -> usr/lib already makes this resolve; only
# add a symlink if it doesn't (e.g. glibc landed the loader somewhere unexpected).
if [ ! -e lib64/ld-linux-x86-64.so.2 ]; then
    loader=$(find . -name 'ld-linux-x86-64.so.2' -not -path './lib64/*' | head -n1)
    if [ -n "$loader" ]; then
        mkdir -p lib64
        ln -sf "/${loader#./}" lib64/ld-linux-x86-64.so.2
    fi
fi

# Build the shared-library search path and cache so the loader finds our libs.
cat > etc/ld.so.conf <<'EOF'
/usr/lib
/usr/local/lib
/lib64
/usr/lib/x86_64-linux-gnu
EOF
ldconfig -r /usr/local/src || true

chown -R root:root etc

chmod 755 etc/systemd/system etc/systemd/network etc/pam.d \
          etc/systemd/system/dbus.service.d
chmod 644 etc/passwd etc/group etc/fstab etc/os-release \
          etc/nsswitch.conf etc/hostname etc/ld.so.conf etc/pam.d/* \
          etc/systemd/network/*.network \
          etc/systemd/system/dbus.service.d/*.conf
# Password hashes must not be world-readable.
chmod 600 etc/shadow

/sbin/mkfs.ext4 -L root -d /usr/local/src /usr/local/output/rootfs.ext4 1G