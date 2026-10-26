# iproute2 builds whatever libraries it finds: libmnl, libelf and libcap (ours), and
# none of the rest. Except libselinux, which the builder has (libblkid-dev pulls it in)
# and the image does not, and which is allowlisted for nscd, so check-rootfs-deps.sh
# would pass an `ip` that cannot start. There is no --without-selinux, so it is hidden
# from pkg-config, and the binary is checked at the end.
cat > /tmp/pkg-config-no-selinux <<'EOF'
#!/bin/sh
for arg; do [ "$arg" = libselinux ] && exit 1; done
exec pkg-config "$@"
EOF
chmod +x /tmp/pkg-config-no-selinux

# --libdir: Debian's pkg-config answers with the multiarch path.
PKG_CONFIG=/tmp/pkg-config-no-selinux ./configure --prefix=/usr --libdir /usr/lib

make

# SBINDIR named, rather than installing through the merged-/usr symlinks.
make install DESTDIR=$ROOTFS PREFIX=/usr SBINDIR=/usr/bin LIBDIR=/usr/lib

# routel is python (constraint 5), and `ip route` says the same.
drop_installed routel

# Everything but ip, ss, bridge, tc and nstat: physical-NIC and host-side hardware, a
# transport the kernel lacks, and old counters nstat and `ip monitor` replace.
drop_installed dcb devlink dpll rdma vdpa netshaper tipc genl \
               ifstat lnstat ctstat rtstat rtacct rtmon

assert_not_linked libselinux usr/bin/ip
