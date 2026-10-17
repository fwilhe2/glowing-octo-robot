# iptables-nft and nothing else: one binary, xtables-nft-multi, answering to iptables,
# ip6tables and their -save/-restore/-translate names, plus the xtables extensions it
# loads from /usr/lib/xtables.
#
# --sysconfdir=/etc: the one file it installs there is ebtables' /etc/ethertypes, which
# goes below, but without this it would land in /usr/etc rather than nowhere.
# --disable-libnfnetlink: only nfnl_osf (passive OS fingerprinting) uses it, and
#   libnfnetlink is not a package here.
# --disable-connlabel: the connlabel match is the one consumer of libnetfilter_conntrack,
#   which is not a package here either.
# Both are pinned rather than left to configure, which would link them the day the
# builder image happens to carry the -dev package (CLAUDE.md, "the three things that
# break silently", the second).
./configure --prefix=/usr \
    --sysconfdir=/etc \
    --disable-static \
    --disable-libnfnetlink \
    --disable-connlabel
make
make install DESTDIR=$ROOTFS

# There is no --disable-legacy, so xtables-legacy-multi is built regardless, and upstream
# points the plain names — iptables, ip6tables and their -save/-restore — at it, leaving
# the nft backend under iptables-nft. Distributions repoint them with alternatives. Here
# the legacy backend cannot work at all: packages/kernel is built without
# NETFILTER_XTABLES_LEGACY, so every iptables-legacy invocation would fail. It goes, and
# the plain names follow the backend that does exist. iptables-xml is a legacy-multi
# applet too, and iptables.xslt is the stylesheet for its output.
drop_installed xtables-legacy-multi iptables-xml \
    iptables-legacy iptables-legacy-save iptables-legacy-restore \
    ip6tables-legacy ip6tables-legacy-save ip6tables-legacy-restore
for name in iptables iptables-save iptables-restore \
            ip6tables ip6tables-save ip6tables-restore; do
    ln -sfn xtables-nft-multi "$ROOTFS/usr/bin/$name"
done
rm -f "$ROOTFS/usr/share/xtables/iptables.xslt"
rmdir "$ROOTFS/usr/share/xtables" 2>/dev/null || true

# ebtables and arptables are the same binary under other names, for nf_tables' bridge
# and arp families. The kernel builds neither (NF_TABLES_BRIDGE, NF_TABLES_ARP), and
# nothing that runs here — Docker, kube-proxy, CNI — uses them, so they would only be
# names that fail. Their extensions and ebtables' /etc/ethertypes go with them; adding
# them back is these lines plus two kernel symbols.
drop_installed ebtables ebtables-nft ebtables-save ebtables-nft-save \
    ebtables-restore ebtables-nft-restore ebtables-translate \
    arptables arptables-nft arptables-save arptables-nft-save \
    arptables-restore arptables-nft-restore arptables-translate
rm -f "$ROOTFS"/usr/lib/xtables/libebt_*.so "$ROOTFS"/usr/lib/xtables/libarpt_*.so
rm -f "$ROOTFS/etc/ethertypes"

# libip4tc and libip6tc are legacy-multi's — the get/set-sockopt interface to the legacy
# tables. With it gone nothing links them, and a library nothing can reach is not one to
# ship. Checked rather than assumed, since a future xtables-nft-multi that started
# linking them would otherwise lose them silently.
for bin in usr/bin/xtables-nft-multi usr/lib/libxtables.so.12 "$ROOTFS"/usr/lib/xtables/*.so; do
    bin=${bin#"$ROOTFS"/}
    assert_not_linked libip4tc "$bin"
    assert_not_linked libip6tc "$bin"
done
rm -f "$ROOTFS"/usr/lib/libip4tc.* "$ROOTFS"/usr/lib/libip6tc.* \
      "$ROOTFS"/usr/lib/pkgconfig/libip4tc.pc "$ROOTFS"/usr/lib/pkgconfig/libip6tc.pc \
      "$ROOTFS"/usr/lib/pkgconfig/libiptc.pc

# The libtool archives go, for the reason packages/libnftnl/build.sh gives.
rm -f "$ROOTFS"/usr/lib/libxtables.la
