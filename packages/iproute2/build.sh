# iproute2's configure is hand-written rather than autotools, and it takes almost no
# options: what gets built is decided by which libraries it finds in the builder image.
# That is the trap builder/deps.txt exists to close, so the list is worth stating —
# found: libmnl (ours), libelf (ours, via elfutils), libcap (ours); not found and
# therefore configured out on their own: libdb (arpd), libtirpc, xtables and ipset (tc's
# iptables-action modules), libbpf.
#
# libselinux is the exception and it is the sharp one. deps.txt does not name it — it is
# in the deliberately-absent list at the bottom of that file — but libblkid-dev and
# friends pull it into the builder image anyway, so configure finds it and links both
# `ip` and `ss` against a library the image does not ship. That failure would not be
# caught: libselinux.so.1 is already on test/known-missing-libs.txt for glibc's nscd, so
# test/check-rootfs-deps.sh would file `ip` under the accepted backlog and pass, and the
# first sign of trouble would be `ip` not starting in qemu.
#
# There is no --without-selinux to pass. What configure does take is $PKG_CONFIG, so hide
# that one library from it and let everything else through. There is no policy in the
# image and no kernel support for one, so nothing is lost.
cat > /tmp/pkg-config-no-selinux <<'EOF'
#!/bin/sh
for arg; do [ "$arg" = libselinux ] && exit 1; done
exec pkg-config "$@"
EOF
chmod +x /tmp/pkg-config-no-selinux

# --libdir is the one thing configure cannot work out: Debian's pkg-config answers with
# the multiarch path, which nothing in the image searches, and LIBDIR is compiled into
# `tc` as where its action plugins live.
PKG_CONFIG=/tmp/pkg-config-no-selinux ./configure --prefix=/usr --libdir /usr/lib

make -j"$(nproc)"

# SBINDIR is /sbin by default and this tree is merged-/usr, so an install would land in
# /usr/bin anyway by following two symlinks. Name it instead: builder/build-package.sh
# stages those links, and a package that installs through them rather than to a real
# path is one staging change away from writing outside the tree.
make install DESTDIR=/usr/local/rootfs PREFIX=/usr SBINDIR=/usr/bin LIBDIR=/usr/lib

# `routel` is #!/usr/bin/env python3, and `make install` puts it beside `ip`. This is
# exactly the case CLAUDE.md's constraint 5 is about — the image ships bash and no other
# interpreter, so this would install as a file that cannot run. Nothing is lost: it
# prints `ip route list` in a different table layout.
rm -f /usr/local/rootfs/usr/bin/routel

# And the assertion the PKG_CONFIG override above is worth nothing without, since the
# thing it prevents is a check that passes. `ip` is the binary this whole package exists
# for; if it came out linked against a library the image has no copy of, stop here rather
# than four CI jobs later in qemu.
if readelf -d /usr/local/rootfs/usr/bin/ip | grep -q selinux; then
    echo "error: ip is linked against libselinux — the PKG_CONFIG override stopped working" >&2
    exit 1
fi
