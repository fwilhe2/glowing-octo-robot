#!/bin/bash
set -euo pipefail

set -x

mkdir -p usr/{sbin,bin} bin sbin boot
mkdir -p {dev,etc,home,lib}
mkdir -p {mnt,opt,proc,srv,sys}
mkdir -p var/{lib,lock,log,run,spool}
install -d -m 0750 root
install -d -m 1777 tmp
mkdir -p usr/{include,lib,share,src}

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

chmod 755 etc/systemd/system etc/pam.d
chmod 644 etc/passwd etc/group etc/fstab etc/os-release \
          etc/nsswitch.conf etc/hostname etc/ld.so.conf etc/pam.d/*
# Password hashes must not be world-readable.
chmod 600 etc/shadow

/sbin/mkfs.ext4 -L root -d /usr/local/src /usr/local/output/rootfs.ext4 1G