#!/bin/bash
set -euo pipefail

set -x

mkdir -p usr/{sbin,bin} boot
mkdir -p {dev,etc,home}
mkdir -p {mnt,opt,proc,srv,sys}
mkdir -p var/{lib,lock,log,run,spool}
install -d -m 0750 root
install -d -m 1777 tmp
mkdir -p usr/{include,lib,share,src}

# usrmerge
ln -s usr/bin /bin
ln -s usr/sbin /sbin
ln -s usr/lib /lib

cp -r /files/* .
ln -sf usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

chown root:root etc/passwd etc/group etc/fstab etc/os-release
# chown root:root etc/systemd/system/default.target
chown root:root etc/systemd/system

chmod 644 etc/passwd etc/group etc/fstab etc/os-release
chmod 755 etc/systemd/system

/sbin/mkfs.ext4 -L root -d /usr/local/src /usr/local/output/rootfs.ext4 1G