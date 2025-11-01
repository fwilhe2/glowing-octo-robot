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
ln -sf usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

chown root:root etc/passwd etc/group etc/fstab etc/os-release
# chown root:root etc/systemd/system/default.target
chown root:root etc/systemd/system

chmod 644 etc/passwd etc/group etc/fstab etc/os-release
chmod 755 etc/systemd/system


echo =========================================================
ls -lR
echo =========================================================

/sbin/mkfs.ext4 -L root -d /usr/local/src /usr/local/output/rootfs.ext4 1G