# Here for iproute2: without it, configure sets HAVE_MNL:=n and drops half the tool set
# (tipc, devlink, rdma, dcb, vdpa) along with the netlink paths `ip` and `tc` use for
# anything newer than rtnetlink. It is also the bottom of the libnftnl/nftables stack
# docs/container-runtime.md phase 3 needs, so it arrives once and stays.
#
# Nothing else to say about the build: autotools, one .so, no optional dependencies to
# configure out. --disable-static because the trim deletes *.a anyway, and not building
# it is cheaper than building it to throw away.
./configure --prefix=/usr --disable-static
make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs
